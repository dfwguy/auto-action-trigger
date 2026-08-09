#!/bin/bash
# The health check runner, run by the node agent: this site's checks in numeric
# order, write each one's output to logs/<node>/<check>, diff that against
# valid-config/default/<check>, and drain this node with the names that differ.
# Checks live in health-checks/$HEALTHCHECKS/NN-<check>.sh -- a platform is a
# directory, so a check that does not apply is a file that is not there.
#
# Check file format -- see docs/reference/health-checks.md#the-check-file-format:
#
#   #!/bin/bash
#   # banner: ########INFO: Check BIOS
#   # informational: yes      (optional -- recorded, never contributes a reason)
#   # reason-detail: yes      (optional -- the check's output joins the reason)
#   <commands writing the check's result to stdout>
#
# The banner is the first line of the log file and the baseline is a copy of
# that file, so its exact text -- including the leading '#' count -- is
# load-bearing: change one and every node fails against every older baseline.
#
# Runs on every agent cycle and re-checks on a cadence, tracing every
# gate to results/<node>/health.log. See docs/explanation/health-cadence.md.

## Located from this file, not a literal path. See docs/reference/layout.md#runtime-paths.
## A missing settings.sh is fatal rather than defaulted: no check directory
## means nothing runs and every node is reported healthy.
## NODE_HEALTH_HOME is for the test suites; nothing in the deployment sets it.
home="${NODE_HEALTH_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run, because" >&2
    echo "               no checks found would report every node as healthy." >&2
    exit 1
fi
source "$home/settings.sh"
source "$home/priv.sh"

## ── Flags ─────────────────────────────────────────────────────────────────
##
## The same surface as launch_job.sh, and for the same reason: this decides
## about the node it runs on, so a sweep is a clush or pdsh over the nodes.
## See docs/how-to/run-a-job-by-hand.md#re-running-health-checks-by-hand.
EXPLAIN=0
FORCE=0
VERBOSE=0; [[ -t 1 ]] && VERBOSE=1
usage() {
    cat <<USAGE
Usage: node_health.sh [--explain] [--force] [--verbose|--quiet]

  --explain, -n   dry run: print every gate, run no check, drain nothing
  --force,   -f   ignore the cadence gate and run the checks now
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Decides about the node it runs on, and takes no node argument. To sweep a set
of nodes, name them where they can be reached:

  clush -w 'ink50-dh01-h02-[11,13-18]' '$home/actions/node_health.sh -f -v'
  pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18]' '$home/actions/node_health.sh -f -v'

With no arguments -- how the node agent invokes it -- the checks re-run once every
HEALTH_INTERVAL_HOURS, or sooner if the last run found something.
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --explain|-n|--dry-run) EXPLAIN=1 ;;
        --force|-f)             FORCE=1 ;;
        --verbose|-v)           VERBOSE=1 ;;
        --quiet|-q)             VERBOSE=0 ;;
        -h|--help)              usage; exit 0 ;;
        *)
            echo "ERROR: unrecognised argument '$arg' -- no checks were run." >&2
            usage >&2
            exit 2 ;;
    esac
done

## Above the sinfo check below, and it says so: that check cannot tell a head
## node from a busy controller, and exits silently either way.
##
## Before the trace directory is created, unlike every gate under it: a
## results/<host> holding only a health trace and no not-a-compute-node marker
## puts the head node back into every report that walks results/*/.
## See docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node.
if node_excluded "$HOSTNAME" || node_self_excluded; then
    echo "########INFO: $HOSTNAME is not a compute node -- health checks not run there"
    exit 0
fi

## ── Tracing ───────────────────────────────────────────────────────────────
##
## Its own file beside trigger.log, read by trigger-log.sh section 5. Every gate
## below writes down why it stopped, or a cadence that has quietly wedged is
## indistinguishable from one with nothing to do.
## See docs/explanation/health-cadence.md#every-cycle-says-what-it-decided.
logs="$home/results/$HOSTNAME"
tracelog="$logs/health.log"
mkdir -p "$logs" 2>/dev/null

TRACE_WRITABLE=-1
trace_writable() {
    [[ "$TRACE_WRITABLE" -ge 0 ]] && return "$TRACE_WRITABLE"
    if { : >> "$tracelog"; } 2>/dev/null; then
        TRACE_WRITABLE=0
    else
        TRACE_WRITABLE=1
        VERBOSE=1
        echo "WARNING: cannot write $tracelog as $(id -un) -- tracing to stdout only." >&2
    fi
    return "$TRACE_WRITABLE"
}
trace() {
    trace_writable && printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$tracelog" 2>/dev/null
    [[ "$EXPLAIN" -eq 1 || "$VERBOSE" -eq 1 ]] && printf '%s\n' "$*"
    return 0
}
if [[ -f "$tracelog" ]] && [[ "$(stat -c %s "$tracelog" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
    tail -2000 "$tracelog" > "$tracelog.tmp" && mv "$tracelog.tmp" "$tracelog"
fi

[[ "$FORCE" -eq 1 ]] && trace "MANUAL: --force -- cadence gate bypassed"

source /etc/profile.d/modules.sh
module load slurm

state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
if [[ -z "$state" ]]
then
        trace "EXIT: 'sinfo -N -n $HOSTNAME' returned nothing, so it is not known whether this is a compute node -- no checks run. A busy controller answers this way too."
        exit 0
fi

reason=""

## Deliberately before the `refresh` sentinel is consumed, so a queued re-check
## survives the pause. See docs/reference/settings.md#pause-switches.
if setting_enabled "$PAUSE_HEALTH_CHECKS"; then
    trace "EXIT: PAUSE_HEALTH_CHECKS=${PAUSE_HEALTH_CHECKS} in ${SETTINGS_FILE:-<none>} -- no checks run, and a queued refresh is held rather than consumed"
    exit 0
fi

## Create valid-config/default by using "ln -s {target} default
valid_health="$home/valid-config/default/"
#valid_health="/cm/shared/apps/bringup/valid-config/air-test/"
node_health="$home/logs/$HOSTNAME/"

## use to gather env data as seen from script
#env > $node_health/script-env

## ── The golden baseline is never the file being written ───────────────────
##
## A baseline pointed at a live logs/<node> was harmless while checks ran once;
## on a cadence every run silently redefines "correct" as whatever that node
## reports now. Fatal, because the alternative is a fleet that agrees with a
## drifting reference. See docs/explanation/health-cadence.md#the-golden-baseline.
## Both resolved, not just equal: readlink -f prints nothing when a parent
## directory is missing, and two empty strings compare equal.
valid_real=$(readlink -f "$valid_health")
node_real=$(readlink -f "$node_health")
if [[ -n "$valid_real" && "$valid_real" == "$node_real" ]]; then
    trace "EXIT: the baseline $valid_health resolves to this node's own log directory, so running the checks here would overwrite the thing they are judged against. Copy it out with 'bash set-valid-default.sh $HOSTNAME' -- that takes a copy rather than a pointer -- then re-run."
    exit 1
fi

if [[ ! -d "$HEALTHCHECKS_DIR" ]]; then
    trace "EXIT: no health check set at $HEALTHCHECKS_DIR (HEALTHCHECKS=$HEALTHCHECKS, from ${SETTINGS_FILE:-<none>}) -- nothing to run, and a node with no checks would otherwise read as healthy."
    exit 1
fi

## ── The cadence gate ──────────────────────────────────────────────────────
##
## The stamp carries the outcome as well as the time: a node that found
## something is re-checked on the shorter interval, and drains being off means
## the outcome is recorded nowhere else.
## See docs/explanation/health-cadence.md#the-stamp-file.
stamp="$node_health/.last-check"
last_epoch=0
last_status=""
if [[ -f "$stamp" ]]; then
    IFS=$'\t' read -r last_epoch last_status < "$stamp" 2>/dev/null
    [[ "$last_epoch" =~ ^[0-9]+$ ]] || { last_epoch=0; last_status=""; }
fi

if [[ "$last_status" == "failed" ]]; then
    interval_hours="$HEALTH_RETRY_INTERVAL_HOURS"
else
    interval_hours="$HEALTH_INTERVAL_HOURS"
fi
[[ "$interval_hours" =~ ^[0-9]+$ ]] || interval_hours=0
age=$(( $(date +%s) - last_epoch ))

if [[ -f "$node_health/refresh" ]]; then
    ## Consumed here and nowhere else, so a refresh queued during a pause is
    ## still waiting when the pause lifts.
    trace "refresh requested by hand -- running the checks now"
    [[ "$EXPLAIN" -eq 1 ]] || rm -f "$node_health/refresh"
elif [[ "$FORCE" -eq 1 ]]; then
    :
elif [[ "$last_epoch" -eq 0 ]]; then
    trace "no ${stamp##*/} -- the checks have not run here since this cadence was deployed; running them now"
elif [[ "$interval_hours" -eq 0 ]]; then
    trace "EXIT: HEALTH_INTERVAL_HOURS=$HEALTH_INTERVAL_HOURS and HEALTH_RETRY_INTERVAL_HOURS=$HEALTH_RETRY_INTERVAL_HOURS in ${SETTINGS_FILE:-<none>} -- the cadence is off, so the checks re-run only when 'health-check.sh --refresh' asks. Last run ${age}s ago: ${last_status:-unknown}."
    exit 0
elif [[ "$age" -lt $(( interval_hours * 3600 )) ]]; then
    trace "EXIT: last run ${age}s ago was ${last_status:-unknown}, and a ${last_status:-clean} run is re-checked every ${interval_hours}h -- next due in $(( interval_hours * 3600 - age ))s"
    exit 0
else
    trace "last run ${age}s ago was ${last_status:-unknown}, past its ${interval_hours}h interval -- re-checking"
fi

## ── The checks that need root ─────────────────────────────────────────────
##
## Below the cadence gate, not above it: this reads every check file to find the
## commands they need, and on a 2,000-node fleet doing that per cycle rather
## than per run is 77,000 NFS reads every couple of minutes for an answer worth
## having every four hours.
##
## Discovered from the check files, so a new one needing a rule is preflighted
## without editing this script. A refused sudo changes a check's output rather
## than failing it, which is why this is fatal.
## See docs/explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run.
mapfile -t priv_cmds < <(grep -hoE 'sudo -n [a-z0-9_.-]+' "$HEALTHCHECKS_DIR"/[0-9]*.sh 2>/dev/null | awk '{print $3}' | sort -u)
if [[ "${#priv_cmds[@]}" -gt 0 ]] && ! priv_ready "${priv_cmds[@]}"; then
    trace "EXIT: sudo as $(id -un) would refuse: $PRIV_MISSING -- the checks needing them would report something other than what the baseline was captured from, so nothing was run and nothing was judged. Those rules come from the site's sudoers deployment; $home/agent/sudoers.default is the reference for what is missing."
    exit 1
fi

if [[ "$EXPLAIN" -eq 1 ]]; then
    trace "--explain: would run $(find "$HEALTHCHECKS_DIR" -maxdepth 1 -name '[0-9]*.sh' | wc -l) check(s) from $HEALTHCHECKS_DIR against $valid_health, and write neither a log nor a drain"
    exit 0
fi

mkdir -p $node_health

append_reason() {
  local header="$1"
  local content="$2"

  # Always add the header
  reason+=$'\n'"${header}"

  # Add content or a placeholder if empty
  if [[ -n "$content" ]]; then
    reason+=$'\n'"${content}"
  else
    reason+=$'\n'"(no output)"
  fi
}

## Read a `# key: value` line from a check's metadata block. Top 10 lines only:
## a whole-file grep would match a check that greps for the same words.
check_meta() {
    local file="$1" key="$2"
    sed -n '1,10p' "$file" | sed -n "s/^# ${key}: *//p" | head -1
}

## ── Run every check in the set ────────────────────────────────────────────
## The numeric prefix fixes the order and is stripped to get the check name,
## which the log, the baseline and the reason all share. Each check runs in its
## own `bash`, never sourced, so one `exit` cannot truncate the set.
## See docs/reference/health-checks.md#the-check-file-format.
for check_file in "$HEALTHCHECKS_DIR"/[0-9]*.sh; do
    [[ -f "$check_file" ]] || continue

    check=$(basename "$check_file" .sh)
    check="${check#*-}"

    banner=$(check_meta "$check_file" banner)
    informational=$(check_meta "$check_file" informational)
    reason_detail=$(check_meta "$check_file" reason-detail)

    ## stderr is deliberately uncaptured: a tool's own complaint belongs in the
    ## agent's output, not in the file being diffed against the baseline.
    out=$(bash "$check_file" 2>/dev/null)

    printf '%s\n' "$banner" > "$node_health/$check"
    printf '%s\n' "$out"   >> "$node_health/$check"

    ## Recorded but never drains -- per-rack values cannot match one
    ## cluster-wide baseline. See docs/reference/health-checks.md#informational-checks.
    [[ "$informational" == "yes" ]] && continue

    ## stderr is kept: "No such file or directory" means the baseline has no
    ## entry for this check, which is not a hardware mismatch.
    if ! diff "$node_health/$check" "$valid_health/$check" > /dev/null; then
        if [[ "$reason_detail" == "yes" ]]; then
            append_reason "$check " "$out"
        else
            append_reason "$check" " "
        fi
    fi
done

#echo >> $node_health
#echo -e "\n########INFO: sysinfo check completed, please review the above information for any potential issue.\n" >> $node_health

## Written before the drain, not after: the drain can fail, and a run whose
## outcome went unrecorded repeats on the next cycle forever.
## See docs/explanation/health-cadence.md#the-stamp-file.
flat_reason=$(echo "${reason}" | tr $'\n' ' ' | sed 's/  */ /g')
printf '%s\t%s\n' "$(date +%s)" "$([[ -n "$reason" ]] && echo failed || echo clean)" > "$stamp"

if [[ -n "$reason" ]]; then
    trace "differs from $valid_health:$flat_reason"
else
    trace "every check matches the baseline"
fi

# -----------------------------------------------------------------------------
# Drain this node in Slurm with the aggregated "reason" text
# -----------------------------------------------------------------------------
node_name=${SLURMD_NODENAME:-$(hostname -s)}

## Both halves go together: resuming a node this script never drained would
## clear somebody else's drain. Every check still runs either way.
## See docs/how-to/manage-drains.md.
if ! setting_enabled "$DRAIN_AFTER_FAILED_HEALTH_CHECK"; then
  if [ -n "${reason}" ]; then
    trace "EXIT: ${node_name} failed health checks, not draining (DRAIN_AFTER_FAILED_HEALTH_CHECK=${DRAIN_AFTER_FAILED_HEALTH_CHECK})"
  fi
  exit 0
fi

if command -v /cm/local/apps/slurm/current/bin/scontrol >/dev/null 2>&1; then
  if [ -z "${reason}" ]; then
    ## A clean run clears only the drains it is evidence against: `health`, the
    ## reasons this script writes itself -- it is the only caller with that
    ## evidence -- plus `machine`. Everything else is left alone.
    ## See docs/explanation/drain-recovery.md.
    if setting_enabled "$PAUSE_RECOVERY"; then
      trace "PAUSE_RECOVERY=${PAUSE_RECOVERY} in ${SETTINGS_FILE:-<none>} -- ${node_name} passed every check but its drain is left where it is"
    elif [[ -f "$home/slurm-recovery.sh" ]]; then
      recover_log() { trace "$@"; }
      ## SC2034: read by slurm-recovery.sh, sourced below, which shellcheck
      ## cannot see from here. Repeated: it covers one assignment.
      # shellcheck disable=SC2034
      RECOVER_ACCEPT="machine health"
      # shellcheck disable=SC2034
      RECOVER_LOG="$home/results/${node_name}/recover.log"
      source "$home/slurm-recovery.sh"
      slurm_recover_node "${node_name}"
    else
      trace "WARNING: $home/slurm-recovery.sh is missing -- ${node_name} passed every check but no drain was cleared. Stale deployment?"
    fi
  else
    trace "DOWN: ${node_name} --$flat_reason"
    scontrol_update NodeName="${node_name}" State=DOWN Reason="$flat_reason"
  fi
else
  trace "WARNING: scontrol not found; unable to update ${node_name} in Slurm."
fi

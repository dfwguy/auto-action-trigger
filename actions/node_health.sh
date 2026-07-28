#!/bin/bash
# BCM finalize script: run the health checks for this site, aggregate the names
# of the ones that do not match the baseline into a "reason" string, then drain
# this node in Slurm with that reason.
#
# The checks themselves are not in this file. Each one is a script in
# health-checks/$HEALTHCHECKS/, named NN-<check>.sh, and this is the runner:
# it executes them in numeric order, writes each one's output to
# logs/<node>/<check>, diffs that against valid-config/default/<check>, and
# collects the names that differ.
#
# One file per check is what makes a second platform possible. This used to be
# one 600-line script of GB200 checks, so supporting anything else meant either
# forking the whole file or wrapping every IMEX and NVLink check in a
# uname/model test until nothing could be read. Now a platform is a directory,
# HEALTHCHECKS names which one runs, and a check that does not apply is a file
# that is not there.
#
# Check file format -- see docs/health-checks.md:
#
#   #!/bin/bash
#   # banner: ########INFO: Check BIOS
#   # informational: yes      (optional -- recorded, never contributes a reason)
#   # reason-detail: yes      (optional -- the check's output joins the reason)
#   <commands writing the check's result to stdout>
#
# The banner is reproduced verbatim as the first line of the log file, and the
# baseline is a copy of that same log file, so its exact text -- including how
# many '#' it starts with -- is load-bearing. Change one and every node fails
# that check against every baseline taken before the change.

source /etc/profile.d/modules.sh
module load slurm

state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
if [[ -z "$state" ]]
then
        exit 0
fi

reason=""

## Settings: HEALTHCHECKS_DIR and DRAIN_AFTER_FAILED_HEALTH_CHECK. BCM invokes
## this by absolute path, so the checkout is located by the hardcoded path
## rather than from $0.
##
## A missing settings.sh is fatal. Defaulting would mean running with no check
## directory, finding nothing to run, and reporting every node as healthy --
## the same silent all-clear a broken baseline gives, and the reason this
## script would rather say nothing than say "fine".
home=/home/cmods/bringup
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run, because" >&2
    echo "               no checks found would report every node as healthy." >&2
    exit 1
fi
source "$home/settings.sh"

## PAUSE_HEALTH_CHECKS=yes stops here -- no checks run, no logs are rewritten,
## and Slurm is not touched in either direction.
##
## Before the `refresh` sentinel is consumed, deliberately. A node queued for a
## re-check by node-health-refresh.sh keeps its sentinel through the pause and
## is re-checked on the first cycle after it lifts; clearing it here would drop
## the request on the floor and leave the operator waiting for a run that is
## never going to happen.
##
## There is no trigger.log on this side, so the pause is announced in the BCM
## action output, which is where this script's other diagnostics go.
if setting_enabled "$PAUSE_HEALTH_CHECKS"; then
    echo "########INFO: PAUSE_HEALTH_CHECKS=${PAUSE_HEALTH_CHECKS} in ${SETTINGS_FILE:-<none>}" \
         "-- health checks not run on ${HOSTNAME}"
    exit 0
fi

## Create valid-config/default by using "ln -s {target} default
valid_health="$home/valid-config/default/"
#valid_health="/cm/shared/apps/bringup/valid-config/air-test/"
node_health="$home/logs/$HOSTNAME/"

## use to gather env data as seen from script
#env > $node_health/script-env


if [[ -d $node_health ]];
then
	if [[ ! -f $node_health/refresh ]];
	then
		exit 0
	else
		rm $node_health/refresh
	fi
fi

mkdir -p $node_health

if [[ ! -d "$HEALTHCHECKS_DIR" ]]; then
    echo "########ERROR: no health check set at $HEALTHCHECKS_DIR" >&2
    echo "               (HEALTHCHECKS=$HEALTHCHECKS, from ${SETTINGS_FILE:-<none>})" >&2
    exit 1
fi

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

## Read a `# key: value` line out of a check file. Only the metadata block at
## the top is consulted -- a grep over the whole file would pick up the same
## words out of a check that greps for them.
check_meta() {
    local file="$1" key="$2"
    sed -n '1,10p' "$file" | sed -n "s/^# ${key}: *//p" | head -1
}

## ── Run every check in the set ────────────────────────────────────────────
##
## Numeric prefixes fix the order, which is the order the reason field lists
## failures in and therefore the order an operator reads them. The prefix is
## stripped to get the check name: the log file, the baseline file and the
## drain reason all use the bare name, so renumbering a check does not
## invalidate a baseline.
##
## Each check runs in its own `bash`, not sourced. A check that sets a shell
## option, exits, or leaves a stray variable behind then cannot take the rest
## of the run with it -- with 38 of them, one `exit 1` in a check that hits an
## unexpected machine would otherwise silently truncate the set and report a
## node as passing everything after it.
for check_file in "$HEALTHCHECKS_DIR"/[0-9]*.sh; do
    [[ -f "$check_file" ]] || continue

    check=$(basename "$check_file" .sh)
    check="${check#*-}"

    banner=$(check_meta "$check_file" banner)
    informational=$(check_meta "$check_file" informational)
    reason_detail=$(check_meta "$check_file" reason-detail)

    ## stderr is deliberately not captured: it goes to the BCM action output
    ## like it always has, so a tool's own complaint is still visible, and it
    ## stays out of the file being diffed against the baseline.
    out=$(bash "$check_file" 2>/dev/null)

    printf '%s\n' "$banner" > "$node_health/$check"
    printf '%s\n' "$out"   >> "$node_health/$check"

    ## Recorded but never drains. These are the checks whose correct value is
    ## per-rack or time-varying, so they cannot match one cluster-wide
    ## baseline: every node outside the baseline node's rack differs by design.
    [[ "$informational" == "yes" ]] && continue

    ## stdout is dropped but stderr is not: "No such file or directory" here
    ## means the baseline has no entry for this check, and that is worth seeing
    ## in the action output rather than being reported as a hardware mismatch.
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

chown -R "$JOB_USER:$JOB_USER" $node_health
# -----------------------------------------------------------------------------
# Drain this node in Slurm with the aggregated "reason" text
# -----------------------------------------------------------------------------
node_name=${SLURMD_NODENAME:-$(hostname -s)}

## DRAIN_AFTER_FAILED_HEALTH_CHECK=no leaves Slurm alone entirely -- no DOWN on
## a mismatch, and no IDLE on a clean run either. Both halves have to go
## together: resuming a node this script never drained would clear somebody
## else's drain, which is the one thing the benchmark side is careful never to
## do.
##
## The result is unchanged whichever way the switch is set. Every check still
## runs, every log is still written, and health-check.sh still reports what
## failed -- from the log files rather than from the Slurm reason field.
if ! setting_enabled "$DRAIN_AFTER_FAILED_HEALTH_CHECK"; then
  if [ -n "${reason}" ]; then
    echo "########INFO: ${node_name} failed health checks, not draining" \
         "(DRAIN_AFTER_FAILED_HEALTH_CHECK=${DRAIN_AFTER_FAILED_HEALTH_CHECK}):" \
         "$(echo "${reason}" | tr $'\n' ' ' | sed 's/  */ /g')"
  fi
  exit 0
fi

if command -v /cm/local/apps/slurm/current/bin/scontrol >/dev/null 2>&1; then
  if [ -z "${reason}" ]; then
    ## A clean run used to be an unconditional `State=IDLE`, which resumed the
    ## node whatever had drained it -- an operator's drain, a benchmark failure
    ## launch_job.sh had just recorded, a reservation. Passing the health
    ## checks says none of those things; it says the checks that drained this
    ## node no longer fail.
    ##
    ## So the same classification the sequencer uses decides it here, with one
    ## more class accepted: `health`, the reasons this script writes itself,
    ## because a clean run is precisely the evidence that they cleared. It is
    ## the only caller that has that evidence, which is why launch_job.sh does
    ## not accept the class and this does.
    ##
    ## `machine` is accepted too -- a node drained for a failed prolog that
    ## then passes every check is a node worth putting back, and the health
    ## trigger reaches nodes on a different cadence to the job trigger.
    ## Everything else, including our own benchmark drain, is left alone.
    if [[ -f "$home/slurm-recovery.sh" ]]; then
      recover_log() { printf '########INFO: %s\n' "$*"; }
      RECOVER_ACCEPT="machine health"
      RECOVER_LOG="$home/results/${node_name}/recover.log"
      source "$home/slurm-recovery.sh"
      slurm_recover_node "${node_name}"
      [[ -f "$RECOVER_LOG" ]] && chown "$JOB_USER:$JOB_USER" "$RECOVER_LOG" 2>/dev/null
    else
      echo "########WARN: $home/slurm-recovery.sh is missing -- ${node_name} passed" \
           "every check but no drain was cleared. Stale deployment?"
    fi
  else
    # Flatten newlines to spaces for the Slurm reason field
    scontrol update NodeName="${node_name}" State=DOWN \
      Reason="$(echo "${reason}" | tr $'\n' ' ' | sed 's/  */ /g')"
  fi
else
  echo "########WARN: scontrol not found; unable to update node in Slurm."
fi

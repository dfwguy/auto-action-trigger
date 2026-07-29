#!/bin/bash
# BCM finalize script and health check runner: run this site's checks in numeric
# order, write each one's output to logs/<node>/<check>, diff that against
# valid-config/default/<check>, and drain this node with the names that differ.
# Checks live in health-checks/$HEALTHCHECKS/NN-<check>.sh -- a platform is a
# directory, so a check that does not apply is a file that is not there.
#
# Check file format -- see docs/health-checks.md#the-check-file-format:
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

source /etc/profile.d/modules.sh
module load slurm

state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
if [[ -z "$state" ]]
then
        exit 0
fi

reason=""

## BCM invokes this by absolute path, so the tree is located by hardcoded path,
## not $0. A missing settings.sh is fatal rather than defaulted: no check
## directory means nothing runs and every node is reported healthy.
home=/home/cmods/bringup
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run, because" >&2
    echo "               no checks found would report every node as healthy." >&2
    exit 1
fi
source "$home/settings.sh"

## Deliberately before the `refresh` sentinel is consumed, so a queued re-check
## survives the pause. See docs/settings.md#pause-switches.
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
## See docs/health-checks.md#the-check-file-format.
for check_file in "$HEALTHCHECKS_DIR"/[0-9]*.sh; do
    [[ -f "$check_file" ]] || continue

    check=$(basename "$check_file" .sh)
    check="${check#*-}"

    banner=$(check_meta "$check_file" banner)
    informational=$(check_meta "$check_file" informational)
    reason_detail=$(check_meta "$check_file" reason-detail)

    ## stderr is deliberately uncaptured: a tool's own complaint belongs in the
    ## BCM action output, not in the file being diffed against the baseline.
    out=$(bash "$check_file" 2>/dev/null)

    printf '%s\n' "$banner" > "$node_health/$check"
    printf '%s\n' "$out"   >> "$node_health/$check"

    ## Recorded but never drains -- per-rack values cannot match one
    ## cluster-wide baseline. See docs/health-checks.md#informational-checks.
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

chown -R "$JOB_USER:$JOB_USER" $node_health
# -----------------------------------------------------------------------------
# Drain this node in Slurm with the aggregated "reason" text
# -----------------------------------------------------------------------------
node_name=${SLURMD_NODENAME:-$(hostname -s)}

## Both halves go together: resuming a node this script never drained would
## clear somebody else's drain. Every check still runs either way.
## See docs/operations.md#disabling-drains.
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
    ## A clean run clears only the drains it is evidence against: `health`, the
    ## reasons this script writes itself -- it is the only caller with that
    ## evidence -- plus `machine`. Everything else is left alone.
    ## See docs/settings.md#recovering-drains-slurm-set-itself.
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

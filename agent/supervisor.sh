#!/bin/bash
#
# The head node's watchdog, run by a systemd --user timer as JOB_USER every
# SUPERVISOR_INTERVAL_MINUTES. Reads sinfo, looks at the heartbeat every node
# writes to the shared tree, and arms the agent on any node that is idle or
# drained and has stopped writing one. Nothing polls a node to ask whether it is
# alive; the answer is already on NFS.
#
# It also carries the one decision a node can no longer make for itself: a job of
# ours running past MAX_JOB_HOURS drains the node from here, because the node's
# own cycle stops at the busy gate.
#
# See docs/explanation/the-agent-and-the-watchdog.md.

home="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run, because" >&2
    echo "               an empty node list reads as a fleet with nothing to do." >&2
    exit 1
fi
source "$home/settings.sh"
source "$home/priv.sh"
# shellcheck source=/dev/null
[[ -f "$home/report-format.sh" ]] && source "$home/report-format.sh"
if [[ ! -f "$home/fanout.sh" ]]; then
    echo "########ERROR: $home/fanout.sh is missing -- it is the only thing here that" >&2
    echo "               reaches a node, so nothing could be armed." >&2
    exit 1
fi
source "$home/fanout.sh"

EXPLAIN=0
VERBOSE=0; [[ -t 1 ]] && VERBOSE=1
usage() {
    cat <<USAGE
Usage: supervisor.sh [--explain] [--verbose|--quiet]

  --explain, -n   dry run: name every node it would arm or drain, and do neither
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Runs on the head node and decides about the whole fleet. The trace is
results/supervisor.log; trigger-log.sh reads it.
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --explain|-n|--dry-run) EXPLAIN=1 ;;
        --verbose|-v)           VERBOSE=1 ;;
        --quiet|-q)             VERBOSE=0 ;;
        -h|--help)              usage; exit 0 ;;
        *)  echo "ERROR: unrecognised argument '$arg' -- nothing was armed." >&2
            usage >&2; exit 2 ;;
    esac
done

results="$home/results"
tracelog="$results/supervisor.log"
mkdir -p "$results" 2>/dev/null

## Tested once, not per line. A watchdog that can neither write nor speak is the
## worst version of the silence this whole design is against: the timer reports a
## clean run, the fleet stops being armed, and nothing anywhere says so. Falling
## back to stdout puts it in the journal, where `systemctl --user status` finds
## it. See docs/explanation/the-agent-and-the-watchdog.md#where-the-watchdog-logs.
TRACE_WRITABLE=-1
trace_writable() {
    [[ "$TRACE_WRITABLE" -ge 0 ]] && return "$TRACE_WRITABLE"
    if { : >> "$tracelog"; } 2>/dev/null; then
        TRACE_WRITABLE=0
    else
        TRACE_WRITABLE=1
        VERBOSE=1
        echo "WARNING: cannot write $tracelog as $(id -un) -- $(stat -c '%U owns %n' "$results" 2>/dev/null || echo "$results does not exist")." >&2
        echo "         Tracing to the journal only: journalctl --user -u bringup-supervisor.service" >&2
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

## ── What "now" is ─────────────────────────────────────────────────────────
##
## Its own mtime on the same share, not this host's clock: both times then come
## from the NFS server, and a head node whose clock has drifted cannot decide the
## whole fleet has stopped. It doubles as the watchdog's own liveness marker --
## the one thing nothing else watches.
## See docs/explanation/the-agent-and-the-watchdog.md#whose-clock-decides.
own_beat="$results/.supervisor-heartbeat"
touch "$own_beat" 2>/dev/null
now=$(stat -c %Y "$own_beat" 2>/dev/null) || now=""
[[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

if setting_enabled "$PAUSE_ARMING" && [[ "$EXPLAIN" -eq 0 ]]; then
    trace "EXIT: PAUSE_ARMING=$PAUSE_ARMING in ${SETTINGS_FILE:-<none>} -- no node is armed. Agents already running are untouched and keep cycling."
    exit 0
fi

## The unit is a login shell, so a site that puts the client tools on PATH from
## /etc/profile.d rather than from a module is covered before this runs.
## See docs/how-to/run-slurm-commands-remotely.md.
slurm_tried="unit runs bash -lc"
if [[ -f /etc/profile.d/modules.sh ]]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/modules.sh
    if declare -F module >/dev/null 2>&1 || command -v module >/dev/null 2>&1; then
        module load slurm 2>/dev/null
        slurm_tried="$slurm_tried, sourced /etc/profile.d/modules.sh, 'module load slurm'"
    else
        slurm_tried="$slurm_tried, sourced /etc/profile.d/modules.sh but it defined no 'module'"
    fi
else
    slurm_tried="$slurm_tried, no /etc/profile.d/modules.sh here"
fi
for tool in sinfo squeue; do
    command -v "$tool" >/dev/null 2>&1 || {
        trace "EXIT: $tool is not on PATH ($slurm_tried; PATH=$PATH) -- which nodes are ready cannot be answered here. If it works in your login shell, whatever puts it there is not reaching this one."
        exit 0
    }
done

## ── Who is ready ──────────────────────────────────────────────────────────
##
## Empty output is not an answer: a saturated slurmctld exits 0 with nothing,
## and believing it would arm, or fail to arm, the entire fleet on no
## information. See docs/explanation/sequencing.md#when-the-controller-does-not-answer.
states=$(sinfo -N -h -o '%N %T' 2>/dev/null)
if [[ -z "$states" ]]; then
    trace "EXIT: 'sinfo -N -h' returned nothing -- no node was armed. A busy controller answers this way too, so nothing here treats it as an empty cluster."
    exit 0
fi

stale_min="$HEARTBEAT_STALE_MINUTES"
[[ "$stale_min" =~ ^[0-9]+$ && "$stale_min" -gt 0 ]] || {
    trace "HEARTBEAT_STALE_MINUTES='$HEARTBEAT_STALE_MINUTES' is not a whole number of minutes -- using 10"
    stale_min=10
}

## Only these two. `draining`, `allocated` and `mixed` have work on them, and a
## trailing `*` is slurmd not answering, which arming does not fix.
## See docs/explanation/the-agent-and-the-watchdog.md#which-states-are-armed.
arm=(); fresh=0; busy=0; unreachable=0; skipped=0; limited=(); waiting=0
inflight_ids=(); inflight_nodes=(); inflight_ages=()

while read -r node state; do
    [[ -n "$node" ]] || continue
    node_excluded "$node" && { skipped=$((skipped + 1)); continue; }

    ## The same filter the sequencer applies, so the watchdog does not arm a node
    ## the site took out of the swept set.
    if [[ -n "${NODE_FILTER// /}" ]]; then
        read -r -a _pats <<< "$NODE_FILTER"
        _match=0
        for _pat in "${_pats[@]}"; do
            # shellcheck disable=SC2053  # a glob on the right is the point
            [[ "$node" == $_pat ]] && { _match=1; break; }
        done
        [[ "$_match" -eq 1 ]] || { skipped=$((skipped + 1)); continue; }
    fi

    ## Collected for the MAX_JOB_HOURS pass below whatever the node's state is:
    ## a job running past its limit is the reason the node is not idle.
    marker="$results/$node/.in-flight"
    if [[ -f "$marker" ]]; then
        IFS=$'\t' read -r _id _name _run _total _submit < "$marker" 2>/dev/null
        if [[ "$_id" =~ ^[0-9]+$ && "$_submit" =~ ^[0-9]+$ ]]; then
            inflight_ids+=("$_id"); inflight_nodes+=("$node"); inflight_ages+=("$(( now - _submit ))")
        fi
    fi

    case "${state,,}" in
        idle|drained) ;;
        *\*)          unreachable=$((unreachable + 1)); continue ;;
        *)            busy=$((busy + 1)); continue ;;
    esac

    beat="$results/$node/.heartbeat"
    age=$(stat -c %Y "$beat" 2>/dev/null) && age=$(( now - age )) || age=-1
    if [[ "$age" -ge 0 && "$age" -lt $(( stale_min * 60 )) ]]; then
        fresh=$((fresh + 1))
        continue
    fi

    ## A node that cannot be armed is reported rather than sshed into every
    ## cycle for ever, on the same shape as RECOVER_MAX_ATTEMPTS.
    armlog="$results/$node/arm.log"
    attempts=0; last=0
    if [[ -f "$armlog" ]]; then
        attempts=$(awk -F'\t' -v c="$(( now - ARM_WINDOW_HOURS * 3600 ))" \
                       '$1 ~ /^[0-9]+$/ && $1 >= c { n++ } END { print n + 0 }' "$armlog")
        last=$(awk -F'\t' '$1 ~ /^[0-9]+$/ { l = $1 } END { print l + 0 }' "$armlog")
    fi
    if [[ "$attempts" -ge "$ARM_MAX_ATTEMPTS" ]]; then
        limited+=("$node")
        continue
    fi
    if [[ "$last" -gt 0 && $(( now - last )) -lt $(( ARM_RETRY_MINUTES * 60 )) ]]; then
        waiting=$((waiting + 1))
        continue
    fi
    arm+=("$node")
done <<< "$states"

## ── Arm them ──────────────────────────────────────────────────────────────
##
## One fan-out across the whole list, not a loop of sshes: output arrives
## labelled with the node it came from, and widening the set costs nothing.
## Nothing is pushed over it -- install-agent.sh reads the units out of this
## same tree, over NFS, on the node.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
armed_list=""
if [[ "${#arm[@]}" -gt 0 ]]; then
    joined=$(IFS=,; printf '%s' "${arm[*]}")
    armed_list=$(declare -F compress >/dev/null && compress "$joined" || printf '%s' "$joined")

    if [[ "$EXPLAIN" -eq 1 ]]; then
        fanout_resolve
        trace "WOULD ARM ${#arm[@]} node(s) with ${FANOUT_CMD:-no fan-out tool}: $armed_list"
    elif ! fanout_resolve; then
        trace "EXIT: $FANOUT_WHY, so ${#arm[@]} node(s) on $HOSTNAME cannot be armed: $armed_list. Nothing was retried and no attempt was recorded."
        exit 0
    else
        trace "ARM ${#arm[@]} node(s) whose heartbeat is older than ${stale_min}m, over $FANOUT_CMD: $armed_list${FANOUT_WHY:+ ($FANOUT_WHY)}"
        out=$(fanout "$joined" "XDG_RUNTIME_DIR=/run/user/\$(id -u) $home/agent/install-agent.sh")
        for node in "${arm[@]}"; do
            said=$(grep "^$node:" <<<"$out" | sed "s/^$node: *//" | tr '\n' ' ')
            printf '%s\t%s\n' "$now" "${said:-no output from $FANOUT_CMD}" >> "$results/$node/arm.log" 2>/dev/null
            case "$said" in
                *FAILED*|"") trace "ARM FAILED $node: ${said:-$FANOUT_CMD said nothing; is ssh as $JOB_USER working from here?}" ;;
            esac
        done
    fi
fi

## ── The job that outran its limit ─────────────────────────────────────────
##
## The node's own cycle stops at the busy gate, so this is the one drain it can
## no longer issue for itself. The marker holds the submit epoch; the controller
## is asked only about the ids that are already past the limit.
## See docs/explanation/sequencing.md#the-busy-gate.
overrun=0
if [[ "${#inflight_ids[@]}" -gt 0 && "$MAX_JOB_HOURS" =~ ^[0-9]+$ && "$MAX_JOB_HOURS" -gt 0 ]]; then
    past=(); past_nodes=(); past_ages=()
    for i in "${!inflight_ids[@]}"; do
        [[ "${inflight_ages[$i]}" -ge $(( MAX_JOB_HOURS * 3600 )) ]] || continue
        past+=("${inflight_ids[$i]}"); past_nodes+=("${inflight_nodes[$i]}"); past_ages+=("${inflight_ages[$i]}")
    done
    if [[ "${#past[@]}" -gt 0 ]]; then
        ids=$(IFS=,; printf '%s' "${past[*]}")
        ## Only RUNNING counts: a job queued behind a dead node reads 0:00 for as
        ## long as it waits, and "timeout" would bury why the node is unusable.
        running=$(squeue -h -o '%i %T' -j "$ids" 2>/dev/null | awk '$2 == "RUNNING" { print $1 }')
        for i in "${!past[@]}"; do
            grep -qx "${past[$i]}" <<<"$running" || continue
            node="${past_nodes[$i]}"; hours=$(( past_ages[i] / 3600 ))
            reason="job timeout after ${hours}h (RUNNING, job ${past[$i]})"
            overrun=$((overrun + 1))
            if ! setting_enabled "$DRAIN_AFTER_FAILED_BENCHMARK"; then
                trace "drain suppressed by DRAIN_AFTER_FAILED_BENCHMARK=$DRAIN_AFTER_FAILED_BENCHMARK: $node -- $reason"
            elif [[ "$EXPLAIN" -eq 1 ]]; then
                trace "WOULD DRAIN $node: $reason"
            else
                trace "DRAIN $node: $reason"
                ## No DRAIN_MARKER: a stuck job stops the retry loop and waits
                ## for a human. See docs/explanation/sequencing.md#when-a-node-is-drained.
                out=$(scontrol_update nodename="$node" state=DRAIN reason="$reason" 2>&1)
                [[ -n "$out" ]] && trace "DRAIN FAILED $node: $out"
            fi
        done
    fi
fi

## ── Say what this cycle decided ───────────────────────────────────────────
##
## Written every cycle including the quiet ones: a watchdog that has stopped
## looks exactly like a fleet with nothing to arm.
summary="checked $(wc -l <<<"$states") node(s): $fresh fresh, ${#arm[@]} armed, $busy with work on them, $unreachable not answering, $skipped filtered out"
[[ "$waiting" -gt 0 ]] && summary+=", $waiting waiting out the ${ARM_RETRY_MINUTES}m arm interval"
[[ "$overrun" -gt 0 ]] && summary+=", $overrun past MAX_JOB_HOURS"
if [[ "${#limited[@]}" -gt 0 ]]; then
    lim=$(IFS=,; printf '%s' "${limited[*]}")
    summary+=". ${#limited[@]} node(s) armed $ARM_MAX_ATTEMPTS time(s) in the last ${ARM_WINDOW_HOURS}h and still silent, left for an operator: $(declare -F compress >/dev/null && compress "$lim" || printf '%s' "$lim")"
fi
trace "$summary"
exit 0

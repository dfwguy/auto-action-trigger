#!/bin/bash
#
# The head node's watchdog, run by a systemd --user timer as JOB_USER every
# SUPERVISOR_INTERVAL_MINUTES. Reads sinfo, looks at the heartbeat every node
# writes to the shared tree, and arms the agent on any node that is idle or
# drained and has stopped writing one. Nothing polls a node to ask whether it is
# alive; the answer is already on NFS.
#
# It is also the only host in the deployment that asks slurmctld anything. Two
# queries here answer for the whole fleet, sharded into one small file per node
# that every agent reads instead of querying for itself --
# docs/explanation/the-fleet-snapshot.md.
#
# And it carries the decisions a node cannot make for itself: a job of ours past
# MAX_JOB_HOURS, the pending jobs a pause has to reach, a job the scheduler gave
# up launching, and giving a node back to somebody who is queued for it.
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
if [[ ! -f "$home/slurm-snapshot.sh" ]]; then
    echo "########ERROR: $home/slurm-snapshot.sh is missing -- without it no node" >&2
    echo "               can be told what Slurm says, and every agent stops deciding." >&2
    exit 1
fi
source "$home/slurm-snapshot.sh"
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
results/supervisor.log; check_trigger-log.sh reads it.
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

results="$RESULTS_DIR"
tracelog="$results/supervisor.log"
mkdir -p "$results" 2>/dev/null

## ── One watchdog cycle at a time ──────────────────────────────────────────
##
## Arming a large fleet takes longer than the interval, and systemd queues a
## start it cannot run concurrently -- so a slow cycle is followed immediately
## by the next, and the fan-out never stops. Node-local, like the agent's.
_sup_lock=/tmp/.bringup-supervisor.lock
if { exec 9>>"$_sup_lock"; } 2>/dev/null && ! flock -n 9 2>/dev/null; then
    exit 0
fi

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

## RUN_ARMING/RUN_JOBS replaced PAUSE_ARMING/PAUSE_JOBS. See
## docs/reference/settings.md#run-switches.
old_setting_present PAUSE_ARMING &&
    trace "WARNING: SETTINGS still sets PAUSE_ARMING -- this key was renamed to RUN_ARMING (RUN_ARMING=no is the equivalent). PAUSE_ARMING is no longer read. Update SETTINGS."
old_setting_present PAUSE_JOBS &&
    trace "WARNING: SETTINGS still sets PAUSE_JOBS -- this key was renamed to RUN_JOBS (RUN_JOBS=no is the equivalent). PAUSE_JOBS is no longer read. Update SETTINGS."

## ── Only one watchdog ─────────────────────────────────────────────────────
##
## Every host runs the same unit and decides its own role, so two that read as
## head -- a second management server, a host that lost its slurmd -- would both
## arm the fleet, race each other's arm.log and double every ssh. A claim on the
## shared tree settles it: whoever holds it keeps it by refreshing, and a claim
## that goes stale is taken over, so the watchdog survives its host dying.
##
## Above the heartbeat below, deliberately: a host standing by must not touch
## the marker that says a watchdog is alive.
## See docs/explanation/the-agent-and-the-watchdog.md#only-one-watchdog.
own_beat="$results/.supervisor-heartbeat"
owner_file="$results/.supervisor-owner"
owner=""
owner_age=-1
if [[ -f "$owner_file" ]]; then
    IFS=$'\t' read -r owner _ < "$owner_file" 2>/dev/null
    ## The one age here measured against this host's clock rather than the
    ## share's: there is no file this host may touch yet. The lease floor below
    ## is far wider than any skew NTP leaves between two management hosts.
    owner_age=$(( $(date +%s) - $(stat -c %Y "$owner_file" 2>/dev/null || echo 0) ))
fi

if [[ -n "${SUPERVISOR_HOST// /}" && "$SUPERVISOR_HOST" != "$HOSTNAME" ]]; then
    trace "EXIT: SUPERVISOR_HOST=$SUPERVISOR_HOST in ${SETTINGS_FILE:-<none>} and this is $HOSTNAME -- nothing is armed from here. The claim is held by ${owner:-nobody}."
    exit 0
fi

## Three cycles, so one slow or skipped run does not hand the fleet over.
lease=$(( ${SUPERVISOR_INTERVAL_MINUTES:-2} * 60 * 3 ))
[[ "$lease" -ge 300 ]] || lease=300
if [[ -n "$owner" && "$owner" != "$HOSTNAME" && "$owner_age" -ge 0 && "$owner_age" -lt "$lease" ]]; then
    trace "EXIT: $owner refreshed the watchdog claim ${owner_age}s ago, so it is the one arming nodes and $HOSTNAME stands by. Two hosts reading as head is worth settling: set SUPERVISOR_HOST, or EXCLUDE_NODES the one that should not be."
    exit 0
fi
if [[ "$EXPLAIN" -eq 0 ]]; then
    claim_tmp="$owner_file.$HOSTNAME.$$"
    if printf '%s\t%s\n' "$HOSTNAME" "$(date +%s)" > "$claim_tmp" 2>/dev/null; then
        mv -f "$claim_tmp" "$owner_file" 2>/dev/null || rm -f "$claim_tmp"
    fi
    [[ -n "$owner" && "$owner" != "$HOSTNAME" ]] &&
        trace "took the watchdog claim from $owner, whose last refresh was ${owner_age}s ago -- past the ${lease}s lease"
fi

## ── What "now" is ─────────────────────────────────────────────────────────
##
## Its own mtime on the same share, not this host's clock: both times then come
## from the NFS server, and a head node whose clock has drifted cannot decide the
## whole fleet has stopped. It doubles as the watchdog's own liveness marker --
## the one thing nothing else watches.
## See docs/explanation/the-agent-and-the-watchdog.md#whose-clock-decides.
beat_age=-1
if [[ -f "$own_beat" ]]; then
    beat_age=$(( $(date +%s) - $(stat -c %Y "$own_beat" 2>/dev/null || date +%s) ))
fi
touch "$own_beat" 2>/dev/null
now=$(stat -c %Y "$own_beat" 2>/dev/null) || now=""
[[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

## One timer fires every host at AGENT_INTERVAL_MINUTES, so this is where the
## watchdog's own cadence lives now.
## See docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles.
if [[ "$EXPLAIN" -eq 0 && "$beat_age" -ge 0 ]] &&
   [[ "$SUPERVISOR_INTERVAL_MINUTES" =~ ^[0-9]+$ ]] &&
   [[ "$beat_age" -lt $(( SUPERVISOR_INTERVAL_MINUTES * 60 )) ]]; then
    exit 0
fi

## Scoped to the arming below rather than exiting, unlike every other pause: the
## snapshot this cycle writes is what the whole fleet decides from, and a paused
## watchdog that stops writing it stops every agent as well.
## See docs/reference/settings.md#run-switches.
ARMING_PAUSED=0
if setting_disabled "$RUN_ARMING" && [[ "$EXPLAIN" -eq 0 ]]; then
    ARMING_PAUSED=1
fi

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
for tool in sinfo squeue scontrol; do
    command -v "$tool" >/dev/null 2>&1 || {
        trace "EXIT: $tool is not on PATH ($slurm_tried; PATH=$PATH) -- which nodes are ready cannot be answered here, and no node can be told either. If it works in your login shell, whatever puts it there is not reaching this one."
        exit 0
    }
done

## ── The fleet's one look at Slurm ─────────────────────────────────────────
##
## Empty output is not an answer: a saturated slurmctld exits 0 with nothing,
## and believing it would arm, or fail to arm, the entire fleet on no
## information -- and would blank two thousand node views at once.
## See docs/explanation/sequencing.md#when-the-controller-does-not-answer.
snapshot_log() { trace "$@"; }
if ! snapshot_query; then
    trace "EXIT: $SNAPSHOT_WRITE_WHY -- no node was armed and no view was rewritten."
    exit 0
fi
states="$SNAPSHOT_NODES"

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
## Every node that gets a view written: the same filter the sequencer applies, so
## the fleet a node believes it is in is the one this walks.
scope=()

## Reason last and free text, so it takes the remainder of the line.
while IFS='|' read -r node state _setter _when _reason; do
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
    scope+=("$node")

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

## ── Tell every node what Slurm said ───────────────────────────────────────
##
## Above the arming and above every pause: this is the only thing a node has to
## decide from, and a cycle that skips it stops the fleet a snapshot age later.
## Not gated on --explain either -- a view is what the controller said, not an
## action taken on it. See docs/explanation/the-fleet-snapshot.md.
if [[ "${#scope[@]}" -eq 0 ]]; then
    trace "WARNING: no node survived EXCLUDE_NODES='$EXCLUDE_NODES' and NODE_FILTER='$NODE_FILTER' -- no view was written, so every agent will stop deciding once the one it has ages out."
elif snapshot_write "$results" "$now" "${scope[@]}"; then
    trace "snapshot: $SNAPSHOT_WRITTEN of ${#scope[@]} node view(s) written"
else
    trace "WARNING: $SNAPSHOT_WRITE_WHY"
fi

## ── Submission circuit breaker ───────────────────────────────────────────
##
## Every failed submitter leaves one small per-node record. When the same
## diagnostic appears across enough nodes inside a short window, stop the fleet
## for a bounded interval instead of making every agent rediscover the outage.
## Slurm remains the atomic accepted-job limiter; this protects its RPC path.
submit_circuit="$results/.submit-circuit"
circuit_active=0; circuit_matches=0; circuit_diag=""
circuit_threshold="$SUBMIT_CIRCUIT_FAILURES"
circuit_window="$SUBMIT_CIRCUIT_WINDOW_MINUTES"
circuit_hold="$SUBMIT_CIRCUIT_HOLD_MINUTES"
[[ "$circuit_threshold" =~ ^[0-9]+$ ]] || circuit_threshold=10
[[ "$circuit_window" =~ ^[1-9][0-9]*$ ]] || circuit_window=5
[[ "$circuit_hold" =~ ^[1-9][0-9]*$ ]] || circuit_hold=10

if [[ -f "$submit_circuit" ]]; then
    IFS=$'\t' read -r _opened _until circuit_matches circuit_diag < "$submit_circuit" 2>/dev/null
    if [[ "$_until" =~ ^[0-9]+$ && "$_until" -gt "$now" ]]; then
        circuit_active=1
    else
        circuit_matches=0
        circuit_diag=""
        [[ "$EXPLAIN" -eq 0 ]] && rm -f "$submit_circuit" 2>/dev/null
    fi
fi

if [[ "$circuit_active" -eq 0 && "$circuit_threshold" -gt 0 ]]; then
    declare -A submit_failure_counts=()
    for node in "${scope[@]}"; do
        retry="$results/$node/.submit-retry"
        [[ -f "$retry" ]] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ _ retry_diag < "$retry" 2>/dev/null
        retry_epoch=$(stat -c %Y "$retry" 2>/dev/null || echo 0)
        [[ "$retry_epoch" =~ ^[0-9]+$ &&
           "$retry_epoch" -ge $(( now - circuit_window * 60 )) ]] || continue
        retry_diag="${retry_diag:-<no output>}"
        submit_failure_counts["$retry_diag"]=$(( ${submit_failure_counts["$retry_diag"]:-0} + 1 ))
    done
    for retry_diag in "${!submit_failure_counts[@]}"; do
        matches="${submit_failure_counts[$retry_diag]}"
        [[ "$matches" -gt "$circuit_matches" ]] || continue
        circuit_matches="$matches"; circuit_diag="$retry_diag"
    done
    if [[ "$circuit_matches" -ge "$circuit_threshold" ]]; then
        circuit_active=1
        circuit_until=$(( now + circuit_hold * 60 ))
        if [[ "$EXPLAIN" -eq 1 ]]; then
            trace "WOULD OPEN submission circuit for ${circuit_hold}m: $circuit_matches matching failures in ${circuit_window}m -- $circuit_diag"
        else
            circuit_tmp="$submit_circuit.$$.tmp"
            if printf '%s\t%s\t%s\t%s\n' "$now" "$circuit_until" \
                "$circuit_matches" "$circuit_diag" > "$circuit_tmp" 2>/dev/null &&
               mv -f "$circuit_tmp" "$submit_circuit" 2>/dev/null; then
                trace "OPEN submission circuit for ${circuit_hold}m: $circuit_matches matching failures in ${circuit_window}m -- $circuit_diag"
            else
                circuit_active=0
                rm -f "$circuit_tmp" 2>/dev/null
                trace "WARNING: could not write $submit_circuit -- the fleet submission storm is not stopped"
            fi
        fi
    fi
fi

## ── Arm them ──────────────────────────────────────────────────────────────
##
## One fan-out across the whole list, not a loop of sshes: output arrives
## labelled with the node it came from, and widening the set costs nothing.
## Nothing is pushed over it -- install-agent.sh reads the units out of this
## same tree, over NFS, on the node.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
## Bounded per cycle. Every arm is an ssh, and ssh is CPU on this host: a fleet
## that has stopped cycling for any reason makes *every* node stale at once, so
## an uncapped pass is two thousand handshakes from one machine, repeated every
## interval. The rest are not lost, only deferred.
## See docs/explanation/the-agent-and-the-watchdog.md#arming-is-bounded.
deferred=0
if [[ "$ARM_BATCH" =~ ^[0-9]+$ ]] && [[ "$ARM_BATCH" -gt 0 ]] && [[ "${#arm[@]}" -gt "$ARM_BATCH" ]]; then
    deferred=$(( ${#arm[@]} - ARM_BATCH ))
    arm=("${arm[@]:0:$ARM_BATCH}")
fi

armed_list=""
if [[ "$ARMING_PAUSED" -eq 1 ]]; then
    trace "RUN_ARMING=$RUN_ARMING in ${SETTINGS_FILE:-<none>} -- ${#arm[@]} node(s) left unarmed. Agents already running are untouched and keep cycling, and this cycle still wrote their views."
    arm=()
fi
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
        trace "ARM ${#arm[@]} node(s) whose heartbeat is older than ${stale_min}m, over $FANOUT_CMD: $armed_list${FANOUT_WHY:+ ($FANOUT_WHY)}${deferred:+$( ((deferred)) && printf '. %s more deferred to the next cycle by ARM_BATCH=%s' "$deferred" "$ARM_BATCH")}"
        ## --quiet: one line per node, so arm.log holds a verdict rather than a
        ## screen of steps. See docs/how-to/arm-a-node.md#one-line-per-node.
        out=$(fanout "$joined" "XDG_RUNTIME_DIR=/run/user/\$(id -u) $home/agent/install-agent.sh --quiet")
        for node in "${arm[@]}"; do
            said=$(grep "^$node:" <<<"$out" | sed "s/^$node: *//" | tr '\n' ' ')
            printf '%s\t%s\n' "$now" "${said:-no output from $FANOUT_CMD}" >> "$results/$node/arm.log" 2>/dev/null
            case "$said" in
                *FAILED*|"")
                    trace "ARM FAILED $node: ${said:-$FANOUT_CMD said nothing within ${FANOUT_COMMAND_TIMEOUT}s; unreachable, or a hung mount on the node}"
                    trace "  what that node says for itself: $FANOUT_CMD -w $node '$home/agent/cycle.sh --verbose'"
                    trace "  and what its own timer's runs said: $FANOUT_CMD -w $node 'journalctl --user -u bringup-agent.service -n 20 --no-pager'"
                    trace "  see docs/how-to/arm-a-node.md#when-a-node-will-not-stay-armed" ;;
            esac
        done
    fi
fi

## ── The job that outran its limit ─────────────────────────────────────────
##
## The node's own cycle stops at the busy gate, so this is the one drain it can
## no longer issue for itself. The marker holds the submit epoch, and which ids
## are running comes out of the queue this cycle already read.
## See docs/explanation/sequencing.md#the-busy-gate.
overrun=0
if [[ "${#inflight_ids[@]}" -gt 0 && "$MAX_JOB_HOURS" =~ ^[0-9]+$ && "$MAX_JOB_HOURS" -gt 0 ]]; then
    past=(); past_nodes=(); past_ages=()
    for i in "${!inflight_ids[@]}"; do
        [[ "${inflight_ages[$i]}" -ge $(( MAX_JOB_HOURS * 3600 )) ]] || continue
        past+=("${inflight_ids[$i]}"); past_nodes+=("${inflight_nodes[$i]}"); past_ages+=("${inflight_ages[$i]}")
    done
    if [[ "${#past[@]}" -gt 0 ]]; then
        ## Only RUNNING counts: a job queued behind a dead node reads 0:00 for as
        ## long as it waits, and "timeout" would bury why the node is unusable.
        running=$(awk -F'|' '$4 == "RUNNING" { print $1 }' <<<"$SNAPSHOT_QUEUE")
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

## ── The queue decisions no node can make any more ─────────────────────────
##
## All three read the one queue this cycle already has, and all three used to be
## a query per node per cycle. The prefix is what makes them safe: nothing here
## touches a job that is not this framework's.
## See docs/explanation/the-fleet-snapshot.md#what-moved-to-the-head-node.
##
## The reason Slurm gives a job it gave up launching. Named rather than inlined
## because an empty pattern matches every job, and the branch it guards cancels.
LAUNCH_FAILED_HELD='launch failed requeued held'

cancel_ids() {
    local what="$1" ids="$2" out
    [[ -n "$ids" ]] || return 0
    if [[ "$EXPLAIN" -eq 1 ]]; then
        trace "WOULD CANCEL $what: $ids"
        return 0
    fi
    if ! command -v scancel >/dev/null 2>&1; then
        trace "WARNING: scancel is not on PATH here -- $what left queued: $ids"
        return 0
    fi
    ## scancel reports a refused kill on stdout and can still exit 0, so the
    ## output is the report and not the status -- as in admin_kill-jobs.sh.
    # shellcheck disable=SC2086  # a deliberate word split: scancel takes a list
    out=$(scancel $ids 2>&1)
    trace "CANCELLED $what: $ids${out:+ -- $out}"
}

paused=0
if setting_disabled "$RUN_JOBS"; then
    ## A pause has to reach the queue too, or it is not a pause: pending jobs go,
    ## a running one is left to finish. See docs/reference/settings.md#run-switches.
    pend=$(awk -F'|' -v p="$SNAPSHOT_PREFIXES" \
        'BEGIN { n = split(p, a, " ") }
         $4 == "PENDING" { for (i = 1; i <= n; i++) if (index($2, a[i]) == 1) { print $1; break } }' \
        <<<"$SNAPSHOT_QUEUE" | tr '\n' ' ')
    paused=$(wc -w <<<"$pend")
    cancel_ids "pending under RUN_JOBS=$RUN_JOBS" "${pend% }"
    while IFS='|' read -r _id _name _rest; do
        [[ -n "$_id" ]] && trace "RUN_JOBS=no: job $_id ($_name) still RUNNING -- left to finish; 'scancel $_id' to stop it now"
    done < <(awk -F'|' -v p="$SNAPSHOT_PREFIXES" \
        'BEGIN { n = split(p, a, " ") }
         $4 == "RUNNING" { for (i = 1; i <= n; i++) if (index($2, a[i]) == 1) { print $1 "|" $2; break } }' \
        <<<"$SNAPSHOT_QUEUE")
fi

## A job held after a failed launch reads as PENDING at priority 0 and never
## starts, so the node waiting on it waits for ever. Its marker goes stale and
## the next cycle there resubmits.
## See docs/explanation/sequencing.md#jobs-the-scheduler-has-given-up-on.
held=""
if [[ -n "$LAUNCH_FAILED_HELD" ]]; then
    held=$(awk -F'|' -v p="$SNAPSHOT_PREFIXES" -v want="$LAUNCH_FAILED_HELD" \
        'BEGIN { n = split(p, a, " ") }
         $4 == "PENDING" && index($0, want) {
             for (i = 1; i <= n; i++) if (index($2, a[i]) == 1) { print $1; break } }' \
        <<<"$SNAPSHOT_QUEUE" | tr '\n' ' ')
    cancel_ids "held after a failed launch ('$LAUNCH_FAILED_HELD')" "${held% }"
fi

## ── Giving a node back ────────────────────────────────────────────────────
##
## The one thing here that cancels a job of ours that is working, so it ships
## off. See docs/explanation/sequencing.md#getting-out-of-the-way.
yielded=0
if [[ -f "$home/get-out-of-the-way.sh" ]]; then
    yield_log() { trace "$@"; }
    # shellcheck disable=SC2034  # read by get-out-of-the-way.sh, sourced below
    YIELD_USER="$JOB_USER"
    # shellcheck disable=SC2034
    YIELD_STAMP="$results/.yield-check"
    # shellcheck disable=SC2034
    YIELD_DRY_RUN="$EXPLAIN"
    source "$home/get-out-of-the-way.sh"
    yield_scan "$results" "$SNAPSHOT_QUEUE" "$now" "$states"
    yielded="$YIELD_CANCELLED"
elif setting_enabled "$GET_OUT_OF_THE_WAY"; then
    trace "WARNING: GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY but $home/get-out-of-the-way.sh is missing -- no node will ever be given up. Stale deployment?"
fi

## ── Say what this cycle decided ───────────────────────────────────────────
##
## Written every cycle including the quiet ones: a watchdog that has stopped
## looks exactly like a fleet with nothing to arm.
summary="checked $(wc -l <<<"$states") node(s): $fresh fresh, ${#arm[@]} armed, $busy with work on them, $unreachable not answering, $skipped filtered out"
[[ "$waiting" -gt 0 ]] && summary+=", $waiting waiting out the ${ARM_RETRY_MINUTES}m arm interval"
[[ "$overrun" -gt 0 ]] && summary+=", $overrun past MAX_JOB_HOURS"
[[ "$deferred" -gt 0 ]] && summary+=", $deferred held back by ARM_BATCH=$ARM_BATCH"
[[ "$paused" -gt 0 ]] && summary+=", $paused pending cancelled by RUN_JOBS=no"
[[ -n "${held// /}" ]] && summary+=", $(wc -w <<<"$held") cancelled after a failed launch"
[[ "$circuit_active" -eq 1 ]] && summary+=", submission circuit open after $circuit_matches matching failure(s)"
[[ "$yielded" -gt 0 ]] && summary+=", $yielded node(s) given up to a waiter"
if [[ "${#limited[@]}" -gt 0 ]]; then
    lim=$(IFS=,; printf '%s' "${limited[*]}")
    lim_pretty=$(declare -F compress >/dev/null && compress "$lim" || printf '%s' "$lim")
    summary+=". ${#limited[@]} node(s) armed $ARM_MAX_ATTEMPTS time(s) in the last ${ARM_WINDOW_HOURS}h and still silent, left for an operator: $lim_pretty"
fi
trace "$summary"

## The give-up list is what somebody reads hours later, so it carries the two
## commands that answer it rather than making them be looked up.
## See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.
if [[ "${#limited[@]}" -gt 0 ]]; then
    trace "  arming them again changes nothing until this is answered -- one cycle in the foreground, which prints every gate:"
    trace "    ${FANOUT_CMD:-clush} -w $lim_pretty '$home/agent/cycle.sh --verbose'"
    trace "  and what their own timers' runs said:"
    trace "    ${FANOUT_CMD:-clush} -w $lim_pretty 'journalctl --user -u bringup-agent.service -n 20 --no-pager'"
    trace "  then 'rm results/<node>/arm.log' to let this try again. docs/how-to/arm-a-node.md#armed-but-never-heartbeats"
fi
exit 0

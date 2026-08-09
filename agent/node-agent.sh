#!/bin/bash
#
# One cycle of work on one node, run by a systemd --user timer as JOB_USER every
# AGENT_INTERVAL_MINUTES. Writes results/<node>/.heartbeat so the head node can
# see from NFS that this node is still cycling, then -- unless a job is running
# here -- runs the container copy, the health checks and the sequencer in turn.
#
# See docs/explanation/the-agent-and-the-watchdog.md.

## Located from this file, like the actions it runs.
## AGENT_HOME is for the test suites; nothing in the deployment sets it.
home="${AGENT_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
if [[ ! -f "$home/settings.sh" ]]; then
    echo "########ERROR: $home/settings.sh is missing -- refusing to run." >&2
    exit 1
fi
source "$home/settings.sh"
source "$home/priv.sh"

EXPLAIN=0
VERBOSE=0; [[ -t 1 ]] && VERBOSE=1
usage() {
    cat <<USAGE
Usage: node-agent.sh [--explain] [--verbose|--quiet]

  --explain, -n   dry run: print every gate, run no step, change nothing
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Decides about the node it runs on and takes no node argument. Normally fired by
the systemd --user timer installed by agent/install-agent.sh; to run one cycle
across a rack by hand:

  clush -w 'ink50-dh01-h02-[11,13-18]' '$home/agent/node-agent.sh -v'
  pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18]' '$home/agent/node-agent.sh -v'
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --explain|-n|--dry-run) EXPLAIN=1 ;;
        --verbose|-v)           VERBOSE=1 ;;
        --quiet|-q)             VERBOSE=0 ;;
        -h|--help)              usage; exit 0 ;;
        *)  echo "ERROR: unrecognised argument '$arg' -- nothing was run." >&2
            usage >&2
            exit 2 ;;
    esac
done

## Above the results directory, as in node_health.sh: a results/<host> holding
## only an agent trace puts the head node back into every report.
## See docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node.
if node_excluded "$HOSTNAME" || node_self_excluded; then
    echo "########INFO: $HOSTNAME is not a compute node -- the node agent does nothing here"
    exit 0
fi

logs="$home/results/$HOSTNAME"
tracelog="$logs/agent.log"
heartbeat="$logs/.heartbeat"
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

## ── The heartbeat ─────────────────────────────────────────────────────────
##
## Before every gate below, and before the lock: it says the timer fired, never
## that the cycle did any work. A paused, busy or wedged node is still a node
## nobody needs to ssh back into.
## See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.
if [[ "$EXPLAIN" -eq 1 ]]; then
    trace "--explain: would touch $heartbeat"
elif ! touch "$heartbeat" 2>/dev/null; then
    trace "WARNING: cannot touch $heartbeat as $(id -un) -- the watchdog will keep arming this node. $(stat -c '%U owns %n' "$logs" 2>/dev/null)"
fi

## ── One cycle at a time ───────────────────────────────────────────────────
##
## A copy or a health run that outlives its interval must not have a second
## cycle started on top of it. Node-local, not on the shared tree: a lock on NFS
## can be held by a node that rebooted.
lock=/tmp/.bringup-agent.lock
started=/tmp/.bringup-agent.started
if [[ "$EXPLAIN" -eq 0 ]] && command -v flock >/dev/null 2>&1; then
    ## Appended to, never truncated: an O_TRUNC open moves the mtime this cycle
    ## is about to read, so the start time lives in its own file.
    if ! exec 9>>"$lock" 2>/dev/null; then
        trace "NOTE: cannot open $lock -- this cycle runs without the one-at-a-time guard"
    elif ! flock -n 9 2>/dev/null; then
        trace "EXIT: the cycle that started $(( $(date +%s) - $(stat -c %Y "$started" 2>/dev/null || date +%s) ))s ago still holds $lock -- this one does nothing"
        exit 0
    else
        touch "$started" 2>/dev/null
    fi
fi

## Local and contacts nothing, so it happens before the busy gate -- which needs
## `scontrol`, and nothing else.
if [[ -f /etc/profile.d/modules.sh ]]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/modules.sh
    module load slurm 2>/dev/null
fi
if ! command -v scontrol >/dev/null 2>&1; then
    trace "EXIT: scontrol is not on PATH after 'module load slurm' (PATH=$PATH) -- whether a job is running here cannot be answered, and every step below needs Slurm anyway."
    exit 0
fi

## ── The busy gate ─────────────────────────────────────────────────────────
##
## Any job at all, ours or a neighbour's. `scontrol listjobs` asks the local
## slurmstepd processes and not slurmctld, so this costs the controller nothing.
## What a busy node stops doing, and where the two behaviours that used to
## depend on running alongside a job went, is
## docs/explanation/sequencing.md#the-busy-gate.
listjobs=$(scontrol listjobs 2>&1); rc=$?
running=$(awk '/^[0-9]+$/ { print }' <<<"$listjobs" | tr '\n' ' ')
running="${running% }"

if [[ "$rc" -ne 0 ]]; then
    trace "BUSY: 'scontrol listjobs' exited $rc (${listjobs//$'\n'/ }) -- read as a job running here, which is the direction that cannot interrupt one"
    exit 0
fi
if [[ -n "$running" ]]; then
    trace "BUSY: job(s) $running running here -- no copy, no health check, no submission"
    ## The one switch this gate makes unreachable, said out loud rather than left
    ## as a setting that quietly does nothing.
    ## See docs/explanation/sequencing.md#getting-out-of-the-way.
    setting_enabled "$GET_OUT_OF_THE_WAY" && \
        trace "NOTE: GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY, but it only ever acts on a job of ours that is running -- which is what this cycle just stopped for. It is reachable only from a hand-run of actions/launch_job.sh."
    exit 0
fi

## ── The three steps ───────────────────────────────────────────────────────
##
## Each in its own `bash`, never sourced, so one step's `exit 1` cannot truncate
## the set -- the same reason the health checks are run that way. Each keeps its
## own gates, its own cadence and its own trace file.
step_args=()
[[ "$EXPLAIN" -eq 1 ]] && step_args+=(--explain)
if [[ "$VERBOSE" -eq 1 ]]; then step_args+=(--verbose); else step_args+=(--quiet); fi

ran=""
for step in file_copy node_health launch_job; do
    script="$home/actions/$step.sh"
    if [[ ! -f "$script" ]]; then
        trace "NOTE: $script is missing -- skipped. Incomplete deployment?"
        continue
    fi
    ## file_copy.sh takes no flags, and has nothing to say about a copy it did
    ## not make, so --explain skips it rather than asking it to explain itself.
    if [[ "$step" == "file_copy" ]]; then
        if [[ "$EXPLAIN" -eq 1 ]]; then
            ran+=" would-run:$step"
            continue
        fi
        bash "$script"
    else
        bash "$script" "${step_args[@]}"
    fi
    rc=$?
    ran+=" $step"
    [[ "$rc" -ne 0 ]] && ran+="(exit $rc)"
done

trace "idle: no job here --${ran:- nothing to run}"
exit 0

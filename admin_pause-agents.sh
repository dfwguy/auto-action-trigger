#!/bin/bash
#
# Usage: admin_pause-agents.sh [--resume] [--status] [--sudo] [-n] [node-pattern]
#
# Stop every agent timer in the fleet, so the exported tree can be replaced
# without cycles running out of it, and start them again afterwards. Run it on
# the head node as JOB_USER.
#
#   (no flag)   stop the watchdog here first, then every matching node's timer.
#               The watchdog goes first on purpose: it re-arms a node whose
#               heartbeat has gone stale, so stopping the nodes while it runs
#               puts them straight back.
#   --resume    the reverse -- re-arm the nodes, then start the watchdog last.
#               Re-arming is agent/install-agent.sh, so it also picks up a unit
#               or an interval that changed in the drop.
#   --status    what is running now: the watchdog here, and how many nodes have
#               written a heartbeat recently. Reads NFS, asks no node.
#   --sudo      re-run explicitly as the JOB_USER configured in SETTINGS.
#               Without this switch, running as another user is refused.
#   -n, --dry-run  print what would be stopped or started, and do neither.
#   pattern     node filter, same rules as report_job-status.sh: a bare string
#               matches by prefix, globs are honored as written.
#
# Both fan-outs give up on a node after FANOUT_COMMAND_TIMEOUT and name it. On
# --resume that is not worth a second pass: a node it missed still has a stale
# heartbeat, so the watchdog arms it on its next cycle, ARM_BATCH at a time. On
# a stop it matters -- an unconfirmed node may still be reading the tree -- and
# --status is what settles that, because it reads heartbeats rather than replies.
#
# This is a stop, not a pause: RUN_JOBS and the rest live in SETTINGS on the
# share, which is unreachable exactly when the share is the problem. Nothing
# re-enables these timers until --resume or install-agent.sh runs.
#
# See docs/how-to/update-the-deployment.md#stragglers-are-the-watchdogs-job.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
source "$home/fanout.sh"

mode=stop
dry=0
use_sudo=0
pattern=""
forward_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume)      mode=resume; forward_args+=("$1"); shift ;;
        --status)      mode=status; forward_args+=("$1"); shift ;;
        --sudo)        use_sudo=1; shift ;;
        -n|--dry-run)  dry=1; forward_args+=("$1"); shift ;;
        -h|--help)     sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*)            echo "ERROR: unknown argument $1" >&2; exit 1 ;;
        *)             pattern="$1"; forward_args+=("$1"); shift ;;
    esac
done

me=$(id -un)
if [[ "$me" != "$JOB_USER" ]]; then
    if [[ "$use_sudo" -eq 1 ]]; then
        command -v sudo >/dev/null 2>&1 || {
            echo "ERROR: running as $me, but the agents run as $JOB_USER, and sudo is not installed." >&2
            exit 1
        }
        echo "switching from $me to configured JOB_USER $JOB_USER through sudo"
        exec sudo -iu "$JOB_USER" bash "$home/admin_pause-agents.sh" "${forward_args[@]}"
    fi
    echo "ERROR: running as $me, but the agents run as JOB_USER=$JOB_USER." >&2
    printf '       Re-run explicitly as that account: %q --sudo' "$home/admin_pause-agents.sh" >&2
    [[ "${#forward_args[@]}" -gt 0 ]] && printf ' %q' "${forward_args[@]}" >&2
    printf '\n' >&2
    exit 1
fi

[[ -z "$pattern" ]] && pattern='*'
[[ "$pattern" != *[\*\?\[]* ]] && pattern="${pattern}*"

## systemctl --user over a fan-out carries no session, so this has to be said
## every time. See docs/how-to/arm-a-node.md.
remote_env='XDG_RUNTIME_DIR=/run/user/$(id -u)'

## From Slurm rather than from results/, so a share that is not answering does
## not decide which nodes exist. EXCLUDE_NODES is honoured: the head node's own
## timer is handled separately and must not be stopped twice.
nodes=()
if command -v sinfo >/dev/null 2>&1; then
    while read -r n; do
        [[ -n "$n" ]] || continue
        # shellcheck disable=SC2053  # a glob on the right is the point
        [[ "$n" == $pattern ]] || continue
        node_excluded "$n" && continue
        [[ "$n" == "$HOSTNAME" ]] && continue
        nodes+=("$n")
    done < <(sinfo -N -h -o '%N' 2>/dev/null | sort -u)
fi
if [[ "${#nodes[@]}" -eq 0 && "$mode" != "status" ]]; then
    echo "ERROR: sinfo named no node matching '${pattern}' -- nothing to do." >&2
    echo "       Without Slurm this cannot work out which nodes to reach." >&2
    exit 1
fi
joined=$(IFS=,; printf '%s' "${nodes[*]}")
pretty="$joined"
[[ -f "$home/report-format.sh" ]] && {
    # shellcheck source=/dev/null
    source "$home/report-format.sh"
    pretty=$(compress "$joined")
}

## The watchdog, here, without touching the share -- which is the whole point.
local_timer() {
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        systemctl --user "$1" bringup-agent.timer 2>&1
}

case "$mode" in
status)
    if XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
       systemctl --user is-active --quiet bringup-agent.timer 2>/dev/null; then
        echo "watchdog on $HOSTNAME: running"
    else
        echo "watchdog on $HOSTNAME: STOPPED -- nothing is arming nodes"
    fi
    ## Two questions, not one. "Within HEARTBEAT_STALE_MINUTES" is what the
    ## watchdog arms on; it is useless for confirming a stop, because a node
    ## stopped a minute ago is still inside that window. What answers a stop is
    ## whether anything is *still writing*.
    ## See docs/how-to/update-the-deployment.md.
    quiet_after=$(( ${AGENT_INTERVAL_MINUTES:-2} * 2 ))
    fresh=0; stale=0; never=0; live=0; newest=-1
    now_s=$(date +%s)
    for n in "${nodes[@]}"; do
        beat="$RESULTS_DIR/$n/.heartbeat"
        if [[ ! -f "$beat" ]]; then never=$((never + 1)); continue; fi
        age=$(( now_s - $(stat -c %Y "$beat" 2>/dev/null || echo 0) ))
        [[ "$newest" -lt 0 || "$age" -lt "$newest" ]] && newest="$age"
        [[ "$age" -lt $(( quiet_after * 60 )) ]] && live=$((live + 1))
        if heartbeat_stale "$RESULTS_DIR" "$n"; then stale=$((stale + 1)); else fresh=$((fresh + 1)); fi
    done
    printf 'nodes matching %s: %d cycling within %sm, %d stale, %d never armed\n' \
        "${pattern}" "$fresh" "$HEARTBEAT_STALE_MINUTES" "$stale" "$never"
    if [[ "$live" -gt 0 ]]; then
        printf 'STILL RUNNING: %d node(s) wrote a heartbeat in the last %dm (newest %ds ago).\n' \
            "$live" "$quiet_after" "$newest"
        echo "  Their timers are firing, so the tree is being read right now. Not safe to replace."
        echo "  '$0' again, then re-check -- a stop that reported ok can still have missed a node."
    else
        printf 'QUIET: nothing has written a heartbeat in %dm (newest %ss ago). Safe to replace the tree.\n' \
            "$quiet_after" "$([[ "$newest" -ge 0 ]] && echo "$newest" || echo "never")"
    fi
    [[ "$stale" -gt 0 || "$never" -gt 0 ]] &&
        echo "  ./check_trigger-log.sh section 0 names the stale and never-armed ones"
    exit 0
    ;;
stop)
    if [[ "$dry" -eq 1 ]]; then
        echo "would stop the watchdog on $HOSTNAME, then ${#nodes[@]} node timer(s): $pretty"
        exit 0
    fi
    ## First, and locally. Stopping the nodes while this is running puts them
    ## straight back, one heartbeat interval later.
    echo "step 1/2: stopping the watchdog on $HOSTNAME"
    out=$(local_timer stop)
    echo "step 1/2 complete: stopped the watchdog on $HOSTNAME${out:+ -- $out}"
    fanout_resolve || { echo "ERROR: $FANOUT_WHY -- the nodes cannot be reached." >&2; exit 1; }
    echo "step 2/2: stopping ${#nodes[@]} node timer(s) over $FANOUT_CMD: $pretty"
    echo "  waiting for the fleet; unreachable nodes may hold this step open for up to ${FANOUT_COMMAND_TIMEOUT}s"
    ## `&& echo STOPPED`, because a successful stop prints nothing and so does a
    ## node the fan-out never reached. Now that the fan-out gives up after
    ## FANOUT_COMMAND_TIMEOUT, those two have to be told apart.
    ## See docs/how-to/update-the-deployment.md#stragglers-are-the-watchdogs-job.
    stop_out=$(fanout "$joined" "$remote_env systemctl --user stop bringup-agent.timer && echo STOPPED")
    echo "step 2/2 complete: the fleet stop pass returned; checking confirmations"
    if bak_resolve; then printf '%s\n' "$stop_out" | bak; else printf '%s\n' "$stop_out" | grep -v '^[^ ]*: *$'; fi
    quiet_nodes=()
    for n in "${nodes[@]}"; do
        grep -q "^$n:.*STOPPED" <<<"$stop_out" || quiet_nodes+=("$n")
    done
    if [[ "${#quiet_nodes[@]}" -gt 0 ]]; then
        silent_list=$(IFS=,; printf '%s' "${quiet_nodes[*]}")
        declare -F compress >/dev/null && silent_list=$(compress "$silent_list")
        printf '\n%d of %d did not confirm a stop: %s\n' \
            "${#quiet_nodes[@]}" "${#nodes[@]}" "$silent_list"
        echo "  Those may still be cycling and reading the tree. --status below is what settles it."
    fi
    ## Not "the fleet is quiet" on the strength of having asked. A stop that
    ## reported nothing can still have missed a node -- one the fan-out could
    ## not reach, or one that is not in sinfo -- and one node still cycling is
    ## one node reading the tree while it is replaced.
    echo "asked ${#nodes[@]} node(s) to stop. Confirm before replacing anything:"
    echo "    $0 --status"
    echo "  It says QUIET only when nothing has written a heartbeat for two cycles."
    ;;
resume)
    if [[ "$dry" -eq 1 ]]; then
        echo "would re-arm ${#nodes[@]} node(s): $pretty"
        echo "then start the watchdog on $HOSTNAME"
        exit 0
    fi
    fanout_resolve || { echo "ERROR: $FANOUT_WHY -- the nodes cannot be reached." >&2; exit 1; }
    ## install-agent.sh rather than `systemctl start`: it also picks up a unit
    ## or an interval that changed in whatever was just copied over, and it
    ## reports per node when a host cannot be armed. --quiet, because a fleet
    ## saying the same thing should read as one line.
    ## See docs/how-to/arm-a-node.md#one-line-per-node.
    echo "step 1/2: re-arming ${#nodes[@]} node(s) over $FANOUT_CMD: $pretty"
    echo "  waiting for the fleet; unreachable nodes may hold this step open for up to ${FANOUT_COMMAND_TIMEOUT}s"
    armed_out=$(fanout "$joined" "$remote_env $home/agent/install-agent.sh --quiet")
    echo "step 1/2 complete: the fleet re-arm pass returned; checking confirmations"
    if bak_resolve; then printf '%s\n' "$armed_out" | bak; else printf '%s\n' "$armed_out"; fi

    ## A node that said nothing is the one the fan-out timed out on or could not
    ## reach, and it is the only outcome the grouped block above cannot show --
    ## there is no line of its own to group. So it is counted and named here.
    ## See docs/how-to/update-the-deployment.md#stragglers-are-the-watchdogs-job.
    armed=0; failed=0; warned=0; quiet_nodes=()
    for n in "${nodes[@]}"; do
        case "$(grep "^$n:" <<<"$armed_out")" in
            *FAILED*)  failed=$((failed + 1)) ;;
            *WARNING*) warned=$((warned + 1)) ;;
            *ARMED*)   armed=$((armed + 1)) ;;
            *)         quiet_nodes+=("$n") ;;
        esac
    done
    printf '\n%d asked, %d armed, %d failed, %d warned, %d unreachable\n' \
        "${#nodes[@]}" "$armed" "$failed" "$warned" "${#quiet_nodes[@]}"
    if [[ "${#quiet_nodes[@]}" -gt 0 ]]; then
        silent_list=$(IFS=,; printf '%s' "${quiet_nodes[*]}")
        declare -F compress >/dev/null && silent_list=$(compress "$silent_list")
        echo "  no answer within ${FANOUT_COMMAND_TIMEOUT}s: $silent_list"
    fi
    [[ "$failed" -gt 0 || "${#quiet_nodes[@]}" -gt 0 ]] &&
        echo "  The watchdog re-arms whatever is still stale, ARM_BATCH per cycle. Leave them to it, or ./check_trigger-log.sh once it has had a cycle."
    ## Last, so it does not arm nodes while the pass above is still going.
    echo "step 2/2: starting the watchdog on $HOSTNAME"
    out=$(local_timer start)
    echo "step 2/2 complete: started the watchdog on $HOSTNAME${out:+ -- $out}"
    ;;
esac

#!/bin/bash
#
# Clearing drains that Slurm set itself. Sourced by actions/launch_job.sh and
# actions/node_health.sh -- never executed.
#
# The problem this exists for: Slurm drains a node for things that are not
# faults of the node. A prolog script that returns non-zero once, a leftover
# process the previous job did not reap, an epilog that lost a race, a batch
# launch that failed while slurmd was restarting -- each of these takes the
# node out of service and leaves it there. Nothing in this framework resumed
# them, because the only resume path was resume_node() in launch_job.sh, which
# deliberately clears nothing that does not carry $DRAIN_MARKER. So the node
# sat drained, the sequencer traced "node is drain for a reason that is not
# ours" every cycle -- true, and useless -- and progress stopped until somebody
# ran `scontrol update ... state=RESUME` by hand, once per node, forever.
#
# The whole difficulty is telling those apart from a drain an operator chose.
# An operator drain must never be cleared by a script: they took the node out
# for a reason this framework cannot see, and resuming it puts work back on a
# node somebody is standing in front of. So a reason is classified, and only
# two of the four classes are ever recoverable:
#
#   marker    our own benchmark drain, carrying $DRAIN_MARKER. Cleared by
#             launch_job.sh's resume_node() when the benchmarks pass, and by
#             nothing here -- a node that passes its health checks has not
#             thereby passed its benchmarks.
#   health    written by node_health.sh: the reason is a list of check names.
#             Recoverable only by node_health.sh itself, and only on a clean
#             run -- it is the only caller that knows the condition cleared.
#   machine   Slurm talking to itself: prolog, epilog, rogue process, failed
#             launch, unexpected reboot. Recoverable, subject to the readiness
#             and rate gates below. RECOVER_REASONS holds the patterns.
#   operator  everything else, including every drain set by a named account.
#             Never touched.
#
# Three independent discriminators have to agree before a machine-class drain
# is cleared, and the narrowest one leads:
#
#   1. the reason matches RECOVER_REASONS, an ERE of machine-generated strings.
#      An operator's reason is prose -- "waiting on RMA", "bad NVLink, do not
#      use" -- and does not match.
#   2. the account that set it is in RECOVER_SETTERS (default: slurm root).
#      A drain set from a named admin account is never cleared, whatever its
#      text says.
#   3. the state is one we can reason about. maint, reserved and fail are left
#      alone: all three are somebody's deliberate arrangement.
#
# The limit, stated rather than papered over: an admin who drains *as root*
# with a reason that happens to match RECOVER_REASONS is indistinguishable
# from Slurm doing it, because Slurm's own drains also land under root on a
# BCM cluster. Discriminator 1 is what carries that weight, which is why the
# shipped pattern list is narrow and is a setting rather than a hardcoded
# "anything that is not ours".
#
# Resuming is not enough on its own: a node put back while still broken is
# re-drained within the minute, and a script that does that in a loop is worse
# than one that does nothing. So a recovery also has to show the condition
# cleared (recover_node_ready) and is rate-limited from a log of its own
# attempts (RECOVER_MAX_ATTEMPTS in RECOVER_WINDOW_HOURS). Past the cap the
# drain is left exactly as Slurm set it -- deliberately not re-drained under
# our own marker, which would hand the node to resume_node() and start the
# flapping again through a different door.
#
# Callers set, before calling slurm_recover_node:
#
#   RECOVER_ACCEPT     which classes this caller may clear, space separated.
#                      launch_job.sh: "machine". node_health.sh, after a clean
#                      run: "machine health".
#   RECOVER_LOG        path to the per-node attempt log. Defaults to
#                      $home/results/<node>/recover.log.
#   RECOVER_DRY_RUN    1 to decide and report but issue nothing (--explain).
#   recover_log()      where trace lines go. A default is defined below if the
#                      caller has not defined one.
#
# Everything else comes from settings.sh: RECOVER_SLURM_DRAINS, RECOVER_REASONS,
# RECOVER_EMPTY_REASON, RECOVER_SETTERS, RECOVER_MAX_ATTEMPTS,
# RECOVER_WINDOW_HOURS, RECOVER_RESTART_SLURMD, DRAIN_MARKER, HEALTHCHECKS_DIR.

## Trace hook. Both callers already have somewhere their output goes -- a
## trigger.log line for launch_job.sh, a ########INFO: line for node_health.sh
## -- and this library must not invent a third place. A caller that defines
## nothing gets stdout, which is what the test harness wants.
if ! declare -F recover_log >/dev/null 2>&1; then
    recover_log() { printf '%s\n' "$*"; }
fi

## Caller-supplied knobs, defaulted so that sourcing this and calling it with
## nothing set is safe rather than surprising: no class is accepted, so the
## answer is "skipped", and nothing is written anywhere.
: "${RECOVER_ACCEPT:=}"
: "${RECOVER_DRY_RUN:=0}"
: "${RECOVER_LOG:=}"

## Reason classification needs to recognise node_health.sh's own reasons, which
## are lists of check names rather than prose. That translation already exists
## and is already shared by two other scripts; a second copy here is how the
## first two drifted. Sourced if it is next to us -- a caller that has already
## sourced it is not made to source it twice.
if ! declare -F canonicalize_reason >/dev/null 2>&1; then
    _recover_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"
    [[ -f "$_recover_home/reason-map.sh" ]] && source "$_recover_home/reason-map.sh"
fi

## sinfo reports "none" for a node with no reason set, and an empty string in
## some releases. Both mean the same thing, and the "for no apparent reason"
## drain -- which is the third of the three cases this was written for -- is
## exactly that: drained, with nothing written down.
recover_reason_empty() {
    local r="$1"
    r="${r#"${r%%[![:space:]]*}"}"
    r="${r%"${r##*[![:space:]]}"}"
    [[ -z "$r" || "$r" == "none" || "$r" == "(null)" ]]
}

## Is every token of this reason the name of a check that exists in the
## configured check set? That -- and not any marker -- is what identifies a
## reason node_health.sh wrote, because it writes check names straight into the
## reason field. One matching token is enough: dmesg-xid drags its own output
## into the reason, so a health reason is not required to be *only* check
## names, and health-check.sh takes the same "any token matches" reading.
recover_reason_is_health() {
    local reason="$1" raw name
    [[ -d "$HEALTHCHECKS_DIR" ]] || return 1
    declare -F canonicalize_reason >/dev/null 2>&1 || return 1
    for raw in $(canonicalize_reason "$reason"); do
        name=$(resolve_token "$raw")
        [[ -n "$name" ]] || continue
        compgen -G "$HEALTHCHECKS_DIR/[0-9]*-$name.sh" >/dev/null 2>&1 && return 0
    done
    return 1
}

## marker | health | machine | operator. Ordered most specific first: our own
## marker wins over everything, because a benchmark drain whose text happened
## to contain the word "prolog" must not be read as Slurm's.
recover_classify() {
    local reason="$1" setter="$2"
    if [[ -n "$DRAIN_MARKER" && "$reason" == *"$DRAIN_MARKER"* ]]; then
        printf 'marker'; return 0
    fi
    if recover_reason_is_health "$reason"; then
        printf 'health'; return 0
    fi
    ## Discriminator 2 comes before the pattern match, so an operator drain is
    ## classified by who set it even when they happened to type something that
    ## looks machine-generated.
    if [[ -n "$setter" && "$setter" != "none" ]] && \
       [[ " ${RECOVER_SETTERS} " != *" $setter "* ]]; then
        printf 'operator'; return 0
    fi
    if recover_reason_empty "$reason"; then
        ## Opt-in on its own: every other class is recognised by something
        ## written down, and this one is recognised by an absence. A site that
        ## does not want a script acting on an inference sets
        ## RECOVER_EMPTY_REASON=no and keeps the rest.
        if setting_enabled "$RECOVER_EMPTY_REASON"; then
            printf 'machine'
        else
            printf 'operator'
        fi
        return 0
    fi
    if [[ -n "$RECOVER_REASONS" ]] && grep -qEi -- "$RECOVER_REASONS" <<<"$reason"; then
        printf 'machine'; return 0
    fi
    printf 'operator'
}

## States we are willing to act on. The trailing `*` sinfo appends means slurmd
## is not answering; it is kept rather than stripped-and-ignored, because it
## decides whether a resume can work at all (see the slurmd branch below).
##
## maint, reserved, planned and fail are all somebody's deliberate arrangement
## -- a reservation, a maintenance window, a state an admin set explicitly --
## and none of them are drains this framework has any business clearing.
recover_state_recoverable() {
    case "${1,,}" in
        *maint*|*reserv*|*planned*|*fail*) return 1 ;;
        *drain*|*down*)                    return 0 ;;
        *)                                 return 1 ;;
    esac
}

## Has the thing that caused the drain actually gone away? Resuming without
## asking is how a node ends up flapping between idle and drained every
## monitoring cycle.
##
## What is checked is deliberately narrow, because a check that cannot be
## satisfied is a node that never comes back:
##
##   slurmd is running     -- a resume on a node whose slurmd is dead puts it
##                            straight back into down*. This is also the only
##                            check that can be repaired here, and only when
##                            RECOVER_RESTART_SLURMD says so.
##   no compute processes  -- the direct test for the rogue-process drain: a
##                            leftover job still holding the GPUs. Only GPU
##                            processes are looked at. A general "no processes
##                            owned by $JOB_USER" test reads a login shell as a
##                            rogue process and never lets the node back.
##   no jobs on the node   -- a drained node with a job still assigned to it is
##                            mid-teardown; let it finish.
##
## Sets RECOVER_NOT_READY to why, for the caller's trace.
RECOVER_NOT_READY=""
recover_node_ready() {
    local node="$1" pids jobs
    RECOVER_NOT_READY=""

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet slurmd 2>/dev/null; then
            if ! setting_enabled "$RECOVER_RESTART_SLURMD"; then
                RECOVER_NOT_READY="slurmd is not active on $node and RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD -- 'systemctl restart slurmd' on the node, or set it to yes"
                return 1
            fi
            if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
                recover_log "WOULD RESTART slurmd on $node (RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD)"
            else
                recover_log "restarting slurmd on $node (RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD)"
                systemctl restart slurmd 2>/dev/null
                if ! systemctl is-active --quiet slurmd 2>/dev/null; then
                    RECOVER_NOT_READY="slurmd did not come back after a restart -- resuming would only put $node back into down*"
                    return 1
                fi
            fi
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -v '^$' | tr '\n' ' ')
        if [[ -n "$pids" ]]; then
            RECOVER_NOT_READY="compute processes still on the GPUs (pids ${pids% })"
            return 1
        fi
    fi

    if command -v squeue >/dev/null 2>&1; then
        jobs=$(squeue -h -w "$node" -o '%i' 2>/dev/null | grep -c .)
        if [[ "$jobs" -gt 0 ]]; then
            RECOVER_NOT_READY="$jobs job(s) still assigned to $node"
            return 1
        fi
    fi
    return 0
}

## Attempt history. One line per recovery, and the file is the only state this
## carries between runs -- same principle as the rest of the sequencer, which
## derives everything it can from files already on disk.
##
## Fields are tab separated with the reason last, because a Slurm reason is
## free text with spaces and tabs are not part of it.
recover_record() {
    local epoch="$1" class="$2" state="$3" setter="$4" reason="$5"
    [[ -n "$RECOVER_LOG" ]] || return 0
    mkdir -p "$(dirname "$RECOVER_LOG")" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$epoch" "$(date -d "@$epoch" '+%F %T' 2>/dev/null)" "$class" "$state" "$setter" \
        "$(tr '\t\n' '  ' <<<"$reason")" >> "$RECOVER_LOG" 2>/dev/null
    ## Same bound as trigger.log: a node that recovers a few times a day still
    ## has a file that only ever grows.
    if [[ "$(stat -c %s "$RECOVER_LOG" 2>/dev/null || echo 0)" -gt 200000 ]]; then
        tail -500 "$RECOVER_LOG" > "$RECOVER_LOG.tmp" 2>/dev/null &&
            mv "$RECOVER_LOG.tmp" "$RECOVER_LOG" 2>/dev/null
    fi
}

## How many recoveries this node has had inside the window. Read from the log
## rather than counted in a variable, so an operator can see the same number
## the gate saw.
recover_attempts_in_window() {
    local now="$1" cutoff n
    cutoff=$(( now - RECOVER_WINDOW_HOURS * 3600 ))
    [[ -f "$RECOVER_LOG" ]] || { printf '0'; return 0; }
    n=$(awk -F'\t' -v c="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= c { n++ } END { print n + 0 }' "$RECOVER_LOG")
    printf '%s' "${n:-0}"
}

## ── Entry point ───────────────────────────────────────────────────────────
##
## Decides about one node and, if everything agrees, resumes it. Returns 0 only
## when the node was actually resumed (or would have been, under --explain), so
## a caller can re-read the node state on 0 and leave it alone otherwise.
##
## RECOVER_RESULT is left holding a one-word outcome for callers that want to
## branch on it: resumed, not-drained, disabled, class, not-ready, rate-limited,
## unknown-node.
RECOVER_RESULT=""
slurm_recover_node() {
    local node="${1:-$HOSTNAME}"
    local line state setter when reason class now attempts out
    RECOVER_RESULT=""

    if ! setting_enabled "$RECOVER_SLURM_DRAINS"; then
        RECOVER_RESULT="disabled"
        return 1
    fi

    ## Reason last, so free text with spaces in it cannot shift a field. The
    ## timestamp and the setter are single tokens; the reason is not.
    line=$(sinfo -N -n "$node" -h -o '%T|%u|%H|%E' 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        RECOVER_RESULT="unknown-node"
        return 1
    fi
    state="${line%%|*}"; line="${line#*|}"
    setter="${line%%|*}"; line="${line#*|}"
    when="${line%%|*}"
    reason="${line#*|}"
    [[ "$setter" == "none" ]] && setter=""
    recover_reason_empty "$reason" && reason=""

    if ! recover_state_recoverable "$state"; then
        RECOVER_RESULT="not-drained"
        return 1
    fi

    class=$(recover_classify "$reason" "$setter")
    if [[ " $RECOVER_ACCEPT " != *" $class "* ]]; then
        ## Named, not silent. "Nothing happened" and "an operator drained this
        ## and we respected it" look identical from outside, and only one of
        ## them is an answer.
        recover_log "recover skipped: $node is $state for a $class reason -- '${reason:-<empty>}'${setter:+ set by $setter}${when:+ at $when}. This caller clears [${RECOVER_ACCEPT:-nothing}]."
        RECOVER_RESULT="class"
        return 1
    fi

    now=$(date +%s)
    attempts=$(recover_attempts_in_window "$now")
    if [[ "$attempts" -ge "$RECOVER_MAX_ATTEMPTS" ]]; then
        ## The drain is left exactly as Slurm set it. Re-draining it under
        ## $DRAIN_MARKER would make it visible in `sinfo -R` as ours, and would
        ## also make it something resume_node() clears on the next clean sweep
        ## -- which is the flapping this cap exists to stop, arriving by
        ## another route. The record is in $RECOVER_LOG and in the trace.
        recover_log "recover skipped: $node recovered $attempts time(s) in the last ${RECOVER_WINDOW_HOURS}h (limit $RECOVER_MAX_ATTEMPTS) -- still '${reason:-<empty>}'. Left drained for an operator; see $RECOVER_LOG."
        RECOVER_RESULT="rate-limited"
        return 1
    fi

    if ! recover_node_ready "$node"; then
        recover_log "recover held: $node is $state ('${reason:-<empty>}', $class) but $RECOVER_NOT_READY"
        RECOVER_RESULT="not-ready"
        return 1
    fi

    if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
        recover_log "WOULD RECOVER $node: $state '${reason:-<empty>}' ($class${setter:+, set by $setter}) -- attempt $((attempts + 1))/$RECOVER_MAX_ATTEMPTS in ${RECOVER_WINDOW_HOURS}h"
        RECOVER_RESULT="resumed"
        return 0
    fi

    out=$(scontrol update nodename="$node" state=RESUME 2>&1)
    if [[ -n "$out" ]]; then
        ## scontrol is quiet on success, so anything here is the failure --
        ## typically "Invalid user id" from a node whose slurm user cannot
        ## update node state. Recorded as an attempt is wrong; it did not
        ## happen.
        recover_log "RECOVER FAILED $node: scontrol update state=RESUME -- $out"
        RECOVER_RESULT="not-ready"
        return 1
    fi

    recover_record "$now" "$class" "$state" "$setter" "$reason"
    recover_log "RECOVER: $node was $state '${reason:-<empty>}' ($class${setter:+, set by $setter}${when:+ at $when}) -- resumed, attempt $((attempts + 1))/$RECOVER_MAX_ATTEMPTS in ${RECOVER_WINDOW_HOURS}h"
    RECOVER_RESULT="resumed"
    return 0
}

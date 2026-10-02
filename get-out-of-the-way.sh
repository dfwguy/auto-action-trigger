#!/bin/bash
#
# Giving a node back when somebody else is queued for it. Experimental --
# GET_OUT_OF_THE_WAY ships off, and the thresholds are expected to move. Sourced
# by agent/supervisor.sh -- never executed, and no longer reachable from a node:
# the whole decision is one pass over the fleet snapshot the head node already
# holds. What counts as a waiter, the four checks a cancel has to pass first, and
# why the prefix is re-read at the scancel itself are in
# docs/explanation/sequencing.md#getting-out-of-the-way.
#
# Callers set before calling yield_scan: YIELD_USER, YIELD_STAMP, YIELD_DRY_RUN,
# and optionally yield_log(). Everything else comes from settings.sh.

if ! declare -F yield_log >/dev/null 2>&1; then
    yield_log() { printf '%s\n' "$*"; }
fi

: "${YIELD_USER:=${JOB_USER:-}}"
: "${YIELD_STAMP:=}"
: "${YIELD_DRY_RUN:=0}"

YIELD_CANCELLED=0
YIELD_RESULT=""

## Every job name this framework submits under. The one gate that does not
## depend on any caller, and it is checked twice -- once when a running job is
## considered, once at the scancel.
## See docs/explanation/sequencing.md#the-prefix-is-the-gate.
YIELD_PREFIXES='bringup- burnin-'

_yield_name_is_ours() {
    local name="$1" p
    for p in $YIELD_PREFIXES; do [[ "$name" == "$p"* ]] && return 0; done
    return 1
}

## `%N|%T|...` as snapshot_query left it, keyed by node. Returns 1 when there is
## nothing to key on, which leaves the check below inert rather than guessing.
declare -A _YIELD_NODE_STATE=()
_yield_load_states() {
    local n st rest
    _YIELD_NODE_STATE=()
    while IFS='|' read -r n st rest; do
        [[ -n "$n" ]] && _YIELD_NODE_STATE[$n]="${st,,}"
    done <<< "$1"
    [[ "${#_YIELD_NODE_STATE[@]}" -gt 0 ]]
}

## Every node carrying somebody else's work, from the same queue: a cancel of
## ours does not free a node a stranger's job is running on.
## See docs/explanation/sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter.
declare -A _YIELD_FOREIGN=()
_yield_load_holders() {
    local id name user state prio subm endt nodes req sched count reason n
    _YIELD_FOREIGN=()
    while IFS='|' read -r id name user state prio subm endt nodes req sched count reason; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        case "$state" in RUNNING|COMPLETING|SUSPENDED|CONFIGURING) ;; *) continue ;; esac
        _yield_name_is_ours "$name" &&
            [[ -n "$YIELD_USER" && "$user" == "$YIELD_USER" ]] && continue
        snapshot_expand "$nodes"
        for n in $_SNAP_HOSTS; do _YIELD_FOREIGN[$n]="job $id ($name, $user)"; done
    done <<< "$1"
}

## Three states and no more. `idle` is free now; `allocated` and `mixed` are free
## the moment the job on them ends, which this can only bring about for a job of
## ours -- so a node a stranger is on is unusable whatever its state, as are
## `draining`, `reserved`, and the `*` of a node that is not answering.
_yield_usable() {
    local n="$1"
    case "${_YIELD_NODE_STATE[$n]:-}" in
        idle|allocated|mixed) ;;
        *) return 1 ;;
    esac
    [[ -z "${_YIELD_FOREIGN[$n]+set}" ]]
}

## Whether a waiter could start if the nodes ours holds were handed back: $1 the
## nodes it named, already expanded and deduplicated, $2 the count it asked for.
## Sets _YIELD_WHY_NOT when it could not. Fewer usable nodes than it needs means
## cancelling for it gives it nothing.
_YIELD_WHY_NOT=""
_yield_can_run() {
    local hosts="$1" want="$2" n usable=0 total=0 bad=""
    _YIELD_WHY_NOT=""
    [[ "${#_YIELD_NODE_STATE[@]}" -gt 0 ]] || return 0

    for n in $hosts; do
        total=$((total + 1))
        if _yield_usable "$n"; then
            usable=$((usable + 1))
        else
            bad+="${bad:+, }$n (${_YIELD_NODE_STATE[$n]:-not in sinfo}${_YIELD_FOREIGN[$n]:+, ${_YIELD_FOREIGN[$n]}})"
        fi
    done
    [[ "$total" -gt 0 ]] || return 0

    ## An unparseable count is read as "it needs the nodes it named", which is
    ## what a -w list means; the strict reading is the one that cancels less.
    [[ "$want" =~ ^[0-9]+$ && "$want" -gt 0 ]] || want="$total"
    [[ "$usable" -ge "$want" ]] && return 0

    _YIELD_WHY_NOT="$usable of the $want node(s) it needs are schedulable -- $bad"
    return 1
}

_yield_minutes() {
    local name="$1" fallback="$2" value="${!1}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        yield_log "WARNING: $name='$value' in ${SETTINGS_FILE:-<no settings file found>} is not a whole number of minutes -- using $fallback."
        printf '%s' "$fallback"
    fi
}

## The only place in this file that cancels, so the prefix is re-read from the
## controller's own answer here rather than trusted from the caller above. The
## watchdog runs as JOB_USER, so Slurm's own ownership check sits under ours.
_yield_cancel() {
    local id="$1" name="$2"
    if ! _yield_name_is_ours "$name"; then
        printf 'refusing to scancel %s: %s does not begin with one of %s\n' \
               "$id" "${name:-<no name>}" "$YIELD_PREFIXES"
        return 0
    fi
    scancel "$id" 2>&1
}

## So the node can say why its job vanished rather than reporting it as gone from
## the queue for no stated reason.
## See docs/explanation/sequencing.md#getting-out-of-the-way.
_yield_breadcrumb() {
    local results="$1" node="$2" text="$3"
    [[ -d "$results/$node" ]] || return 0
    printf '%s\t%s\n' "$(date +%s)" "${text//[$'\t\n']/ }" \
        > "$results/$node/.yielded" 2>/dev/null
}

## $1 the results tree, $2 the fleet queue as snapshot_query left it, $3 now, $4
## the node states as snapshot_query left them. One pass: build the set of nodes
## somebody else is waiting on and could actually use, then cancel the job of
## ours running on each. Returns 0 always -- every outcome is traced.
# shellcheck disable=SC2034  # endt/reason are placeholders: the free text reason
                             # has to be the last field read, so it is named
yield_scan() {
    local results="$1" queue="$2" now="$3" states="${4:-}"
    local after poll age id name user state prio subm endt nodes req sched count reason
    local pend n out text hosts
    local -A wanted_by=() yielded_for=() seen=()
    YIELD_CANCELLED=0
    YIELD_RESULT=""

    setting_enabled "$GET_OUT_OF_THE_WAY" || { YIELD_RESULT="disabled"; return 0; }
    if ! command -v scancel >/dev/null 2>&1; then
        YIELD_RESULT="no-scancel"
        yield_log "WARNING: GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY but scancel is not on PATH here -- no node can be given up"
        return 0
    fi
    [[ -n "$queue" ]] || { YIELD_RESULT="empty-queue"; return 0; }

    after=$(_yield_minutes GET_OUT_OF_THE_WAY_AFTER_MINUTES 5)
    poll=$(_yield_minutes GET_OUT_OF_THE_WAY_POLL_MINUTES 5)

    ## One stamp for the fleet now, not one per node: this costs the controller
    ## nothing any more, and the gate is only still here because cancelling a job
    ## that is working is the one destructive thing this framework does.
    if [[ -n "$YIELD_STAMP" && -f "$YIELD_STAMP" ]]; then
        age=$(( now - $(stat -c %Y "$YIELD_STAMP" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt $(( poll * 60 )) ]]; then
            YIELD_RESULT="polled-recently"
            return 0
        fi
    fi
    [[ -n "$YIELD_STAMP" && "$YIELD_DRY_RUN" -ne 1 ]] && : > "$YIELD_STAMP" 2>/dev/null

    ## Without it every waiter reads as able to run, which is what this did before
    ## the states were passed in -- inert, not wrong.
    if _yield_load_states "$states"; then
        _yield_load_holders "$queue"
    else
        yield_log "no node states passed to the scan -- a waiter whose nodes are drained cannot be told from one that would start"
    fi

    ## ── Who is waiting, and for which nodes ────────────────────────────────
    while IFS='|' read -r id name user state prio subm endt nodes req sched count reason; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [[ "$state" == "PENDING" ]] || continue
        ## Ours by name, on this node or any other: a bringup job waiting its turn
        ## is not somebody being kept off the cluster.
        _yield_name_is_ours "$name" && continue
        ## Priority 0 is Slurm's own word for held, and a held job never starts.
        ## docs/explanation/sequencing.md#a-held-job-is-not-a-waiter
        [[ "$prio" == 0 ]] && continue

        pend=$(date -d "$subm" +%s 2>/dev/null) || continue
        [[ "$pend" =~ ^[0-9]+$ ]] || continue
        pend=$(( now - pend ))
        [[ "$pend" -ge $(( after * 60 )) ]] || continue

        ## Both lists, deduplicated: they answer different questions and overlap,
        ## and a node counted twice is a node counted as two usable ones.
        seen=(); hosts=""
        snapshot_expand "$req";   for n in $_SNAP_HOSTS; do
            [[ -n "${seen[$n]+set}" ]] || { seen[$n]=1; hosts+="$n "; }; done
        snapshot_expand "$sched"; for n in $_SNAP_HOSTS; do
            [[ -n "${seen[$n]+set}" ]] || { seen[$n]=1; hosts+="$n "; }; done
        [[ -n "$hosts" ]] || continue

        ## Cancelling a benchmark for a job that cannot start anyway gives the
        ## nodes to nobody, exactly as yielding to a held job did.
        ## See docs/explanation/sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter.
        if ! _yield_can_run "$hosts" "$count"; then
            yield_log "not a waiter: job $id ($name, $user) pending $(( pend / 60 ))m cannot start -- $_YIELD_WHY_NOT"
            continue
        fi

        for n in $hosts; do
            wanted_by[$n]="job $id ($name, $user) pending $(( pend / 60 ))m"; done
    done <<< "$queue"

    [[ "${#wanted_by[@]}" -gt 0 ]] || { YIELD_RESULT="no-waiter"; return 0; }

    ## ── What of ours is on one of those nodes ──────────────────────────────
    ## Four checks, all against the snapshot rather than any marker: our name,
    ## our user, RUNNING, and on a node somebody is waiting for.
    while IFS='|' read -r id name user state prio subm endt nodes req sched count reason; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        [[ "$state" == "RUNNING" ]] || continue
        _yield_name_is_ours "$name" || continue
        [[ -n "$YIELD_USER" && "$user" == "$YIELD_USER" ]] || continue

        snapshot_expand "$nodes"
        for n in $_SNAP_HOSTS; do
            [[ -n "${wanted_by[$n]+set}" ]] || continue
            text="cancelled our job $id ($name) to get out of the way of ${wanted_by[$n]}"
            if [[ "$YIELD_DRY_RUN" -eq 1 ]]; then
                yield_log "WOULD YIELD $n: $text"
                yielded_for[$n]=1
                YIELD_CANCELLED=$((YIELD_CANCELLED + 1))
                break
            fi
            ## scancel reports a refused kill on stdout and can still exit 0, so
            ## the output is the report and not the status -- as in admin_kill-jobs.sh.
            out=$(_yield_cancel "$id" "$name")
            if [[ -n "$out" ]]; then
                yield_log "WARNING: scancel $id said '$out' -- $n was not given up, and ${wanted_by[$n]} is still waiting"
                break
            fi
            _yield_breadcrumb "$results" "$n" "$text"
            yield_log "YIELDED $n: $text"
            yielded_for[$n]=1
            YIELD_CANCELLED=$((YIELD_CANCELLED + 1))
            break
        done
    done <<< "$queue"

    ## A node somebody is queued for that this did not give up is the interesting
    ## half: it means nothing of ours is running there, or what is running failed
    ## one of the four checks. Without this line that is indistinguishable from
    ## the scan never having run.
    local held=""
    for n in "${!wanted_by[@]}"; do
        [[ -n "${yielded_for[$n]+set}" ]] || held+="${held:+, }$n (${wanted_by[$n]})"
    done
    [[ -n "$held" ]] &&
        yield_log "not yielded, nothing of ours confirmed running there: $held"

    # shellcheck disable=SC2034  # read by the sourcing caller's summary line
    YIELD_RESULT="scanned"
    return 0
}

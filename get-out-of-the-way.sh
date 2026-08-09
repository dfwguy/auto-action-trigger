#!/bin/bash
#
# Giving the node back when somebody else is queued for it. Experimental --
# GET_OUT_OF_THE_WAY ships off, and the thresholds are expected to move. Sourced
# by actions/launch_job.sh -- never executed. What counts as a waiter, the four
# checks a cancel has to pass first, why the name prefix is checked again at the
# scancel itself, and why the check is polled rather than run every cycle are in
# docs/explanation/sequencing.md#getting-out-of-the-way.
#
# Callers set before calling yield_to_waiter: YIELD_OURS (the job names this
# node is allowed to cancel, space separated), YIELD_USER, YIELD_STAMP,
# YIELD_DRY_RUN, and optionally yield_log(). Everything else comes from
# settings.sh. YIELD_RESULT is left holding what happened.

if ! declare -F yield_log >/dev/null 2>&1; then
    yield_log() { printf '%s\n' "$*"; }
fi

## Defaulted so that calling this with nothing set cancels nothing, rather than
## surprising the caller: an empty YIELD_OURS matches no job name below.
: "${YIELD_OURS:=}"
: "${YIELD_USER:=${JOB_USER:-}}"
: "${YIELD_STAMP:=}"
: "${YIELD_DRY_RUN:=0}"

YIELD_RESULT=""
YIELD_WAITER=""

## Every job name this framework submits under. The one gate that does not
## depend on the caller getting YIELD_OURS right, and it is checked twice --
## see docs/explanation/sequencing.md#the-prefix-is-the-gate.
YIELD_PREFIXES='bringup- burnin-'

_yield_name_is_ours() {
    local name="$1" p
    for p in $YIELD_PREFIXES; do [[ "$name" == "$p"* ]] && return 0; done
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

## squeue -O pads every field to its default width, so the `|` separators arrive
## with the padding still attached.
_yield_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

## Whether a Slurm node list holds this node. Expanded with `scontrol show
## hostnames` rather than matched as text: the list arrives compressed, and
## nothing in ink50-dh01-i01-[11-18] contains ink50-dh01-i01-13. Answers are
## cached because one node list is usually shared by several pending jobs.
declare -A _YIELD_EXPANDED=()
_yield_holds_node() {
    local node="$1" list="$2" n
    case "${list,,}" in ''|'n/a'|'(null)'|none) return 1 ;; esac
    if [[ -z "${_YIELD_EXPANDED[$list]:-}" ]]; then
        _YIELD_EXPANDED[$list]=no
        while IFS= read -r n; do
            [[ "$n" == "$node" ]] && { _YIELD_EXPANDED[$list]=yes; break; }
        done < <(scontrol show hostnames "$list" 2>/dev/null)
    fi
    [[ "${_YIELD_EXPANDED[$list]}" == yes ]]
}

## The first pending job that wants this node and is not ours. Prints
## "id user name pending-seconds"; returns 2 when the queue could not be read,
## which is not the same answer as "nobody is waiting" and must not act like it.
_yield_waiter() {
    local node="$1" after="$2" queue rc id user name req sched pend prio
    queue=$(squeue -h -t PENDING \
                -O 'JobID:|,UserName:|,Name:|,ReqNodes:|,SchedNodes:|,PendingTime:|,PriorityLong:|' 2>&1)
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        yield_log "WARNING: squeue would not list the pending queue, so nothing is yielded to: ${queue:-<no output>}"
        return 2
    fi
    [[ -n "$queue" ]] || return 1

    while IFS='|' read -r id user name req sched pend prio _; do
        id=$(_yield_trim "$id")
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        name=$(_yield_trim "$name")
        ## Ours by name, on this node or any other: a bringup job waiting its
        ## turn is not somebody being kept off the cluster.
        _yield_name_is_ours "$name" && continue
        ## Priority 0 is Slurm's own word for held, and a held job never starts.
        ## docs/explanation/sequencing.md#a-held-job-is-not-a-waiter
        [[ "$(_yield_trim "$prio")" == 0 ]] && continue
        pend=$(_yield_trim "$pend")
        [[ "$pend" =~ ^[0-9]+$ ]] || pend=0
        [[ "$pend" -lt "$after" ]] && continue
        _yield_holds_node "$node" "$(_yield_trim "$req")" ||
            _yield_holds_node "$node" "$(_yield_trim "$sched")" || continue
        printf '%s %s %s %s\n' "$id" "$(_yield_trim "$user")" "$name" "$pend"
        return 0
    done <<< "$queue"
    return 1
}

## Four checks, all of them against the controller's own answer rather than the
## marker that got us here: right id, our user, one of this node's own job
## names, and running on this node. Any doubt leaves the job alone.
_yield_job_is_ours() {
    local want="$1" node="$2" line id user name state nodes ours n
    line=$(squeue -h -j "$want" -O 'JobID:|,UserName:|,Name:|,State:|,NodeList:|' 2>/dev/null)
    if [[ -z "$line" ]]; then
        YIELD_RESULT="gone"
        yield_log "not yielding: job $want is no longer in the queue"
        return 1
    fi
    if [[ "$(grep -c . <<<"$line")" -ne 1 ]]; then
        YIELD_RESULT="unconfirmed"
        yield_log "not yielding: 'squeue -j $want' answered $(grep -c . <<<"$line") lines, so the job it names is not certain"
        return 1
    fi

    IFS='|' read -r id user name state nodes _ <<< "$line"
    id=$(_yield_trim "$id"); user=$(_yield_trim "$user"); name=$(_yield_trim "$name")
    state=$(_yield_trim "$state"); nodes=$(_yield_trim "$nodes")

    [[ "$id" == "$want" ]] || {
        YIELD_RESULT="unconfirmed"
        yield_log "not yielding: asked about job $want and squeue answered for $id"
        return 1
    }
    [[ -n "$YIELD_USER" && "$user" == "$YIELD_USER" ]] || {
        YIELD_RESULT="not-ours"
        yield_log "not yielding: job $want belongs to '$user', not $YIELD_USER"
        return 1
    }
    ours=0
    for n in $YIELD_OURS; do [[ "$name" == "$n" ]] && ours=1; done
    ## Both, not either: YIELD_OURS is what this node submitted under, the
    ## prefix is what every job of this framework's is named.
    [[ "$ours" -eq 1 ]] && _yield_name_is_ours "$name" || {
        YIELD_RESULT="not-ours"
        yield_log "not yielding: job $want is named '$name', which is not one of this node's own (${YIELD_OURS:-<none>})"
        return 1
    }
    [[ "$state" == "RUNNING" ]] || {
        YIELD_RESULT="not-running"
        yield_log "not yielding: job $want is $state, so it is not what is holding $node"
        return 1
    }
    _yield_holds_node "$node" "$nodes" || {
        YIELD_RESULT="elsewhere"
        yield_log "not yielding: job $want is running on '$nodes', which does not include $node"
        return 1
    }
    _YIELD_CONFIRMED_NAME="$name"
    return 0
}

## The only place in this file that cancels, so the prefix can be re-read from
## the controller's own answer here rather than trusted from the checks above.
## Dropping to JOB_USER puts Slurm's ownership check under ours; the login shell
## is what puts the client tools on PATH. See
## docs/explanation/sequencing.md#the-prefix-is-the-gate.
_yield_cancel() {
    local id="$1" name="$2"
    if ! _yield_name_is_ours "$name"; then
        printf 'refusing to scancel %s: %s does not begin with one of %s\n' \
               "$id" "${name:-<no name>}" "$YIELD_PREFIXES"
        return 0
    fi
    if [[ "$EUID" -eq 0 ]]; then
        su - "$YIELD_USER" -c "source /etc/profile.d/modules.sh; module load slurm; scancel $id" 2>&1
    else
        scancel "$id" 2>&1
    fi
}

## $1 the job id from the marker, $2 this node. Returns 0 only when that job was
## cancelled, which is the caller's signal to clear the marker.
yield_to_waiter() {
    local want="$1" node="$2" after poll waiter wid wuser wname wpend out age tool
    YIELD_RESULT=""
    YIELD_WAITER=""
    _YIELD_CONFIRMED_NAME=""

    setting_enabled "$GET_OUT_OF_THE_WAY" || { YIELD_RESULT="disabled"; return 1; }
    [[ "$want" =~ ^[0-9]+$ ]] || { YIELD_RESULT="no-job"; return 1; }
    for tool in squeue scancel scontrol; do
        command -v "$tool" >/dev/null 2>&1 && continue
        YIELD_RESULT="no-slurm"
        yield_log "WARNING: GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY but $tool is not on PATH -- the node cannot be given up"
        return 1
    done

    after=$(_yield_minutes GET_OUT_OF_THE_WAY_AFTER_MINUTES 5)
    poll=$(_yield_minutes GET_OUT_OF_THE_WAY_POLL_MINUTES 5)

    ## A cycle with a job running costs the controller nothing, and this is the
    ## one thing that would change that. See
    ## docs/explanation/sequencing.md#what-a-yield-costs.
    if [[ -n "$YIELD_STAMP" && -f "$YIELD_STAMP" ]]; then
        age=$(( $(date +%s) - $(stat -c %Y "$YIELD_STAMP" 2>/dev/null || echo 0) ))
        if [[ "$age" -lt $(( poll * 60 )) ]]; then
            YIELD_RESULT="polled-recently"
            return 1
        fi
    fi
    [[ -n "$YIELD_STAMP" && "$YIELD_DRY_RUN" -ne 1 ]] && : > "$YIELD_STAMP" 2>/dev/null

    waiter=$(_yield_waiter "$node" $(( after * 60 )))
    case "$?" in
        1) YIELD_RESULT="no-waiter"; return 1 ;;
        2) YIELD_RESULT="no-queue-answer"; return 1 ;;
    esac
    read -r wid wuser wname wpend <<< "$waiter"
    YIELD_WAITER="job $wid ($wname, $wuser) pending $(( wpend / 60 ))m for $node"

    _yield_job_is_ours "$want" "$node" || return 1

    if [[ "$YIELD_DRY_RUN" -eq 1 ]]; then
        YIELD_RESULT="would-yield"
        yield_log "WOULD CANCEL our job $want to get out of the way of $YIELD_WAITER"
        return 1
    fi

    ## scancel reports a refused kill on stdout and can still exit 0, so the
    ## output is the report and not the status -- as in kill-jobs.sh.
    out=$(_yield_cancel "$want" "$_YIELD_CONFIRMED_NAME")
    if [[ -n "$out" ]]; then
        YIELD_RESULT="cancel-failed"
        yield_log "WARNING: scancel $want said '$out' -- the node was not given up, and $YIELD_WAITER is still waiting"
        return 1
    fi
    # shellcheck disable=SC2034  # read by the sourcing caller and asserted on
                                 # by tests/yield-test.sh; dead only in here
    YIELD_RESULT="yielded"
    yield_log "YIELDED $node: cancelled our job $want to get out of the way of $YIELD_WAITER"
    return 0
}

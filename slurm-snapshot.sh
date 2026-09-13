#!/bin/bash
#
# The fleet's view of Slurm, taken once on the head node and read from NFS by
# every node. Sourced by agent/supervisor.sh (the writer) and by
# actions/launch_job.sh, actions/node_health.sh and slurm-recovery.sh (the
# readers) -- never executed.
#
# Why no node may ask slurmctld for itself, why the per-node view is sharded
# rather than shared, and what a reader owes a stale view are in
# docs/explanation/the-fleet-snapshot.md.
#
# Readers call snapshot_load, which returns 1 with SNAPSHOT_WHY set when there
# is no usable answer -- which is not the same as "nothing is queued" and must
# never be allowed to act like it.

if ! declare -F snapshot_log >/dev/null 2>&1; then
    snapshot_log() { printf '%s\n' "$*"; }
fi

## Every job name this framework submits under, and the only ones anything here
## counts or reports. The yield library re-reads the same list at its scancel.
SNAPSHOT_PREFIXES='bringup- burnin-'

## One file per node beside its heartbeat, never one fleet-wide file every node
## reads. See docs/explanation/the-fleet-snapshot.md#why-it-is-sharded.
SNAPSHOT_VIEW=".slurm-view"
SNAPSHOT_DIR=".slurm"

## ── Reading ───────────────────────────────────────────────────────────────

SNAPSHOT_AGE=-1
SNAPSHOT_WHY=""
SNAPSHOT_STATE=""
SNAPSHOT_SETTER=""
SNAPSHOT_WHEN=""
SNAPSHOT_REASON=""
SNAPSHOT_GRES=""
SNAPSHOT_CPUTOT=""
SNAPSHOT_JOBS=()
SNAPSHOT_OURS=()
SNAPSHOT_LOADED=0

## Three watchdog cycles, floored at five minutes, so one slow or skipped run on
## the head node does not stop the fleet deciding anything.
snapshot_max_age() {
    local m="${SLURM_SNAPSHOT_MAX_AGE_MINUTES:-}"
    [[ "$m" =~ ^[0-9]+$ && "$m" -gt 0 ]] || m=$(( ${SUPERVISOR_INTERVAL_MINUTES:-2} * 3 ))
    [[ "$m" -ge 5 ]] || m=5
    printf '%s' "$m"
}

## Asked once per run and remembered: several gates want the same answer, and it
## cannot change inside one cycle. $1 the results tree, $2 this node.
# shellcheck disable=SC2034  # every SNAPSHOT_* set here is read by the sourcing
                             # caller, which shellcheck cannot see from in here
snapshot_load() {
    local dir="$1" node="$2" file key rest id state user endt name
    local maxage now mtime sealed=0
    [[ "$SNAPSHOT_LOADED" -eq 1 ]] && { [[ -z "$SNAPSHOT_WHY" ]]; return; }
    SNAPSHOT_LOADED=1
    SNAPSHOT_WHY=""
    SNAPSHOT_JOBS=(); SNAPSHOT_OURS=()

    file="$dir/$node/$SNAPSHOT_VIEW"
    if [[ ! -r "$file" ]]; then
        SNAPSHOT_WHY="no $file -- the watchdog writes one every cycle, so either it has stopped or this node is not in the set it walks"
        return 1
    fi

    while IFS=$'\t' read -r key rest; do
        case "$key" in
            state)  SNAPSHOT_STATE="$rest" ;;
            setter) SNAPSHOT_SETTER="$rest" ;;
            when)   SNAPSHOT_WHEN="$rest" ;;
            gres)   SNAPSHOT_GRES="$rest" ;;
            cputot) SNAPSHOT_CPUTOT="$rest" ;;
            reason) SNAPSHOT_REASON="$rest" ;;
            job)    IFS=$'\t' read -r id state user endt name <<<"$rest"
                    SNAPSHOT_JOBS+=("$id"$'\t'"$state"$'\t'"$user"$'\t'"$endt"$'\t'"$name") ;;
            ours)   SNAPSHOT_OURS+=("$rest") ;;
            end)    sealed=1 ;;
        esac
    done < "$file"

    ## The sentinel, not the file's existence: the writer truncates in place, so
    ## a reader that arrives mid-write sees a prefix and nothing else says so.
    ## See docs/explanation/the-fleet-snapshot.md#a-torn-read-says-nothing.
    if [[ "$sealed" -eq 0 ]]; then
        SNAPSHOT_WHY="$file has no end marker, so it was being rewritten as this cycle read it"
        return 1
    fi

    maxage=$(snapshot_max_age)
    now=$(date +%s)
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
    SNAPSHOT_AGE=$(( now - mtime ))
    if [[ "$SNAPSHOT_AGE" -ge $(( maxage * 60 )) ]]; then
        SNAPSHOT_WHY="$file is ${SNAPSHOT_AGE}s old, past the ${maxage}m this trusts -- the watchdog has stopped writing it. 'systemctl --user status bringup-supervisor.service' on the head node"
        return 1
    fi
    return 0
}

## Jobs Slurm has assigned to this node, ours and everyone else's:
## `id state user endepoch name`, one per line. A PENDING job has no node list
## and is not here -- snapshot_job is what answers about one of those.
snapshot_jobs_here() {
    [[ "${#SNAPSHOT_JOBS[@]}" -gt 0 ]] && printf '%s\n' "${SNAPSHOT_JOBS[@]}"
    return 0
}

## Every job carrying one of this node's two names, wherever it is in the queue:
## `id state name reason`, reason last because it is free text.
snapshot_ours() {
    [[ "${#SNAPSHOT_OURS[@]}" -gt 0 ]] && printf '%s\n' "${SNAPSHOT_OURS[@]}"
    return 0
}

## One job of ours by id. Sets rather than prints, so a caller does not lose the
## reason to a subshell -- the same reason verdict() works the way it does.
SNAPSHOT_JOB_STATE=""
SNAPSHOT_JOB_REASON=""
snapshot_job() {
    local want="$1" line id state name reason
    SNAPSHOT_JOB_STATE=""; SNAPSHOT_JOB_REASON=""
    for line in "${SNAPSHOT_OURS[@]}"; do
        IFS=$'\t' read -r id state name reason <<<"$line"
        [[ "$id" == "$want" ]] || continue
        # shellcheck disable=SC2034  # read by the sourcing caller
        SNAPSHOT_JOB_STATE="$state"
        # shellcheck disable=SC2034
        SNAPSHOT_JOB_REASON="$reason"
        return 0
    done
    return 1
}

snapshot_name_is_ours() {
    local name="$1" p
    for p in $SNAPSHOT_PREFIXES; do [[ "$name" == "$p"* ]] && return 0; done
    return 1
}

## ── Writing ───────────────────────────────────────────────────────────────

SNAPSHOT_WRITE_WHY=""
SNAPSHOT_NODES=""
SNAPSHOT_QUEUE=""
SNAPSHOT_HW=""
SNAPSHOT_QUERIED=0
SNAPSHOT_WRITTEN=0

## `%E` is free text.  Some Slurm versions render an embedded newline as an
## indented physical continuation line, even with `-o`; that line must remain
## part of the preceding reason, never become a node named after the reason.
## A node name is deliberately not matched against a site hostname convention:
## it only has to be one safe path component, and the fixed state field proves
## that this is one of the records requested below.
snapshot_node_record() {
    local line="$1" node state reason
    [[ "$line" =~ ^[^\|]*\|[^\|]*\|[^\|]*\|[^\|]*\| ]] || return 1
    # The setter and timestamp establish the positions of the fields we need,
    # but do not affect whether this is a node record.
    IFS='|' read -r node state _ _ reason <<< "$line"
    [[ -n "$node" && "$node" != *[[:space:]]* && "$node" != */* &&
       "$node" != . && "$node" != .. ]] || return 1
    [[ "$state" =~ [[:alpha:]] ]] || return 1
    [[ "$state" =~ ^[[:alnum:]_+*~#%:@!?-]+$ ]] || return 1
    return 0
}

snapshot_normalize_nodes() {
    local line record="" continuation
    while IFS= read -r line || [[ -n "$line" ]]; do
        if snapshot_node_record "$line"; then
            [[ -n "$record" ]] && printf '%s\n' "$record"
            record="$line"
        elif [[ -n "$record" ]]; then
            ## Slurm indents continuations.  A reason is written to one line in
            ## the view, so trim that indentation and join it with one space.
            continuation="${line#"${line%%[![:space:]]*}"}"
            continuation="${continuation%"${continuation##*[![:space:]]}"}"
            [[ -n "$continuation" ]] && record+=" $continuation"
        elif [[ -n "${line//[[:space:]]/}" ]]; then
            ## stderr keeps this diagnostic out of the command substitution.
            snapshot_log "WARNING: ignoring orphaned malformed sinfo output: $line" >&2
        fi
    done
    [[ -n "$record" ]] && printf '%s\n' "$record"
}

## `%e` is start plus the job's own limit, absolute, so nothing downstream parses
## a Slurm duration. An unlimited job reports N/A and keeps it: read as
## "expired", it would take a node out of service over a job that is fine.
snapshot_end_epoch() {
    local end="$1" epoch
    case "${end,,}" in ''|n/a|unknown|unlimited|infinite) printf 'none'; return 0 ;; esac
    epoch=$(date -d "$end" +%s 2>/dev/null)
    if [[ "$epoch" =~ ^[0-9]+$ ]]; then printf '%s' "$epoch"; else printf 'none'; fi
}

## Slurm node lists arrive compressed, and nothing in ink50-dh01-i01-[11-18]
## contains ink50-dh01-i01-13. Expanded once per distinct list here, which is
## the whole reason no node ever has to. Sets _SNAP_HOSTS, never prints: a
## command substitution would fork once per job in the queue.
declare -A _SNAP_EXPANDED=()
_SNAP_HOSTS=""
snapshot_expand() {
    local list="$1"
    _SNAP_HOSTS=""
    case "${list,,}" in ''|'n/a'|'(null)'|none) return 0 ;; esac
    if [[ -z "${_SNAP_EXPANDED[$list]+set}" ]]; then
        _SNAP_EXPANDED[$list]=$(scontrol show hostnames "$list" 2>/dev/null | tr '\n' ' ')
    fi
    _SNAP_HOSTS="${_SNAP_EXPANDED[$list]}"
}

## The two fleet-wide queries, and the only ones anything in this tree makes.
## Reason is last in each format: a Slurm reason is free text with spaces.
## See docs/explanation/the-fleet-snapshot.md#the-two-queries.
# shellcheck disable=SC2034  # SNAPSHOT_WRITE_WHY is what the caller traces
snapshot_query() {
    local rc
    SNAPSHOT_WRITE_WHY=""
    SNAPSHOT_NODES=""; SNAPSHOT_QUEUE=""; SNAPSHOT_HW=""
    SNAPSHOT_QUERIED=0

    SNAPSHOT_NODES=$(sinfo -N -h -o '%N|%T|%u|%H|%E' 2>/dev/null |
                     snapshot_normalize_nodes)
    if [[ -z "$SNAPSHOT_NODES" ]]; then
        SNAPSHOT_WRITE_WHY="'sinfo -N -h' returned nothing. A saturated controller answers this way too, so no view is rewritten and every node keeps the one it has until that ages out"
        return 1
    fi

    ## Its own call rather than two more fields above: %E is free text and has to
    ## be last, and these two are what a count drain is judged against. See
    ## docs/explanation/drain-recovery.md#a-count-drain-is-checked-against-the-hardware.
    SNAPSHOT_HW=$(sinfo -N -h -o '%N|%G|%c' 2>/dev/null)

    SNAPSHOT_QUEUE=$(squeue -h -a -o '%i|%j|%u|%T|%Q|%V|%e|%N|%n|%Y|%D|%r' 2>&1); rc=$?
    if [[ "$rc" -ne 0 || "$SNAPSHOT_QUEUE" == *"error:"* ]]; then
        SNAPSHOT_WRITE_WHY="squeue would not list the queue, so no view is rewritten: ${SNAPSHOT_QUEUE:-<no output>}"
        SNAPSHOT_QUEUE=""
        return 1
    fi
    SNAPSHOT_QUERIED=1
    return 0
}

## $1 the results tree, $2 the epoch to stamp, $3.. every node to write a view
## for. Returns 1 with SNAPSHOT_WRITE_WHY set when the controller did not answer.
# shellcheck disable=SC2034  # subm/req/sched/count place the free
                             # text reason in the last field; the counters below
                             # are read by the caller's summary line
snapshot_write() {
    local results="$1" now="$2"; shift 2
    local id name user state prio subm endt nodes req sched count reason
    local n node dir written=0
    local -A jobs_here=() ours_by_node=() gres=() cputot=()
    local -A state_of=() setter_of=() when_of=() reason_of=()

    ## The caller may have queried already -- the supervisor has to walk the node
    ## list to work out which nodes are even in scope before this can run.
    [[ "$SNAPSHOT_QUERIED" -eq 1 ]] || snapshot_query || return 1

    ## Fleet-wide copies for the head node's own tools and for anyone debugging
    ## a view. Nothing on a compute node reads these.
    dir="$results/$SNAPSHOT_DIR"
    mkdir -p "$dir" 2>/dev/null
    printf '%s\n' "$SNAPSHOT_NODES" > "$dir/nodes.psv.$HOSTNAME.$$" 2>/dev/null &&
        mv -f "$dir/nodes.psv.$HOSTNAME.$$" "$dir/nodes.psv" 2>/dev/null
    printf '%s\n' "$SNAPSHOT_QUEUE" > "$dir/queue.psv.$HOSTNAME.$$" 2>/dev/null &&
        mv -f "$dir/queue.psv.$HOSTNAME.$$" "$dir/queue.psv" 2>/dev/null

    while IFS='|' read -r id name user state prio subm endt nodes req sched count reason; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        reason="${reason//[$'\t\n']/ }"

        if snapshot_name_is_ours "$name"; then
            ## Keyed on the name, which carries the node it was submitted for: a
            ## PENDING job has no node list at all, and that is precisely the case
            ## the submit guard exists for.
            ours_by_node[${name#*-}]+="ours"$'\t'"$id"$'\t'"$state"$'\t'"$name"$'\t'"$reason"$'\n'
        fi

        snapshot_expand "$nodes"
        for n in $_SNAP_HOSTS; do
            jobs_here[$n]+="job"$'\t'"$id"$'\t'"$state"$'\t'"$user"$'\t'"$(snapshot_end_epoch "$endt")"$'\t'"$name"$'\n'
        done
    done <<< "$SNAPSHOT_QUEUE"

    while IFS='|' read -r n prio state; do
        [[ -n "$n" ]] || continue
        gres[$n]="$prio"; cputot[$n]="$state"
    done <<< "$SNAPSHOT_HW"

    while IFS='|' read -r n state user endt reason; do
        [[ -n "$n" ]] || continue
        state_of[$n]="$state";  setter_of[$n]="$user"
        when_of[$n]="$endt";    reason_of[$n]="${reason//[$'\t\n']/ }"
    done <<< "$SNAPSHOT_NODES"

    for node in "$@"; do
        [[ -n "${state_of[$node]+set}" ]] || continue
        [[ -d "$results/$node" ]] || mkdir -p "$results/$node" 2>/dev/null || continue
        ## Truncated in place and sealed with `end` rather than renamed: a rename
        ## per node per cycle is two thousand extra forks on one host, and a
        ## reader that sees a prefix already has an answer -- no answer.
        {
            printf 'stamp\t%s\n'  "$now"
            printf 'state\t%s\n'  "${state_of[$node]}"
            printf 'setter\t%s\n' "${setter_of[$node]}"
            printf 'when\t%s\n'   "${when_of[$node]}"
            printf 'gres\t%s\n'   "${gres[$node]:-}"
            printf 'cputot\t%s\n' "${cputot[$node]:-}"
            printf '%s' "${jobs_here[$node]:-}"
            printf '%s' "${ours_by_node[$node]:-}"
            printf 'reason\t%s\n' "${reason_of[$node]}"
            printf 'end\t%s\n'    "$now"
        } > "$results/$node/$SNAPSHOT_VIEW" 2>/dev/null && written=$((written + 1))
    done

    SNAPSHOT_WRITTEN="$written"
    return 0
}

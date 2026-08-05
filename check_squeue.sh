#!/bin/bash
#
# Usage: check_squeue.sh [-j <jobid>[,<jobid>...]]
#
# With no argument, the whole queue in one table: job id, state, node count and
# start time first, then the two node lists and the reason -- the fields that
# run long go last. Every job on the cluster, not just this framework's.
#
#   -j, --job <jobid>
#            report on one job, repeatable and comma-separated. Adds what the
#            queue line leaves out when a job sits PENDING: the state and drain
#            reason of every node it is waiting on, and any reservation holding
#            those nodes. A ReqNodeNotAvail line names neither.
#
#            The nodes examined are the job's allocation once it is running,
#            and its requested nodes while it is pending -- the requested list
#            is the one that explains a PD job.
#
#            It also names the running jobs holding those nodes. A pending job
#            whose nodes are all `allocated` is queued behind them, and neither
#            the node table nor a `Resources` reason says whose they are.
#
#            The queue line comes last, so the same table is the last thing on
#            screen either way.
#
# A job id that is no longer in the queue is reported as such and the run
# continues to the next one; it is not an error. Nothing here writes anything.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---
fmt='%i|%t|%D|%S|%N|%n|%r'

jobs=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -j|--job)  next_is_job=1 ;;
        -*)        echo "ERROR: unknown option $arg -- see check_squeue.sh -h" >&2; exit 1 ;;
        *)
            if [[ -n "$next_is_job" ]]; then
                IFS=',' read -r -a ids <<< "$arg"
                jobs+=("${ids[@]}")
                next_is_job=
            else
                echo "ERROR: unexpected argument $arg -- job ids go after -j" >&2
                exit 1
            fi
            ;;
    esac
done
if [[ -n "$next_is_job" ]]; then
    echo "ERROR: -j takes a job id" >&2
    exit 1
fi

if ! command -v squeue &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

if [[ "${#jobs[@]}" -eq 0 ]]; then
    squeue -o "$fmt" | column -t -s'|'
    exit 0
fi

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# The job's nodes, one key each; set_want fills it and overlap counts against
# it. See docs/how-to/diagnose-nothing-running.md#reading-the-queue.
declare -A want=()

set_want() {
    want=()
    local n
    while IFS= read -r n; do
        [[ -n "$n" ]] && want["$n"]=1
    done < <(scontrol show hostnames "$1" 2>/dev/null)
    [[ "${#want[@]}" -gt 0 ]]
}

overlap() {
    local n hit=0
    while IFS= read -r n; do
        [[ -n "${want[$n]}" ]] && ((++hit))
    done < <(scontrol show hostnames "$1" 2>/dev/null)
    printf '%s' "$hit"
}

# Running jobs holding any of the job's nodes, $1 being the job itself.
blocking_jobs() {
    local jid user name left nodes hit
    while IFS='|' read -r jid user name left nodes; do
        [[ "$jid" == "$1" || -z "$nodes" ]] && continue
        hit=$(overlap "$nodes")
        [[ "$hit" -gt 0 ]] &&
            printf '  %-8s %-10s %-30s %10s left  %d of the job'"'"'s nodes\n' \
                "$jid" "$user" "$name" "$left" "$hit"
    done < <(squeue -h -t RUNNING,COMPLETING -o '%i|%u|%j|%L|%N' 2>/dev/null)
}

# Reservations whose node list overlaps the job's nodes, one line each.
covering_reservations() {
    local line name nodes state users hit
    while IFS= read -r line; do
        [[ "$line" == *ReservationName=* ]] || continue
        name="${line#*ReservationName=}"; name="${name%% *}"
        nodes="${line#*Nodes=}";           nodes="${nodes%% *}"
        state="${line#*State=}";           state="${state%% *}"
        users="${line#*Users=}";           users="${users%% *}"

        hit=$(overlap "$nodes")
        [[ "$hit" -gt 0 ]] &&
            printf '  %s  State=%s  Users=%s  %d of the job'"'"'s nodes\n' \
                "$name" "$state" "$users" "$hit"
    done < <(scontrol show res -o 2>/dev/null)
}

for id in "${jobs[@]}"; do
    echo "================================================================"
    echo "Job $id"
    echo "================================================================"

    detail=$(squeue -h -j "$id" -o '%j|%u|%P|%T|%r|%l|%M|%V|%S' 2>/dev/null)
    if [[ -z "$detail" ]]; then
        echo "  not in the queue -- it finished, was cancelled, or never existed"
        echo "  Slurm keeps a finished job for MinJobAge only; try:"
        echo "      sacct -j $id"
        echo
        continue
    fi

    IFS='|' read -r name user part state reason limit elapsed submit start <<< "$detail"
    printf '  %-12s %s\n' Name "$(trim "$name")" State "$(trim "$state")" \
                          User "$(trim "$user")" Partition "$(trim "$part")" \
                          Reason "$(trim "$reason")" TimeLimit "$(trim "$limit")" \
                          Elapsed "$(trim "$elapsed")" Submitted "$(trim "$submit")" \
                          Started "$(trim "$start")"

    alloc=$(squeue -h -j "$id" -o '%N' 2>/dev/null | tr -d ' ')
    req=$(squeue -h -j "$id" -o '%n' 2>/dev/null | tr -d ' ')
    if [[ -n "$alloc" ]]; then
        nodes="$alloc"; which_nodes="allocated"
    else
        nodes="$req"; which_nodes="requested"
    fi

    echo
    if [[ -z "$nodes" ]]; then
        echo "  no $which_nodes nodes -- the job names none, so no node state to show"
    else
        echo "  $which_nodes nodes ($nodes):"
        sinfo -N -o "%N|%T|%E" -n "$nodes" 2>/dev/null | column -t -s'|' | sed 's/^/  /'

        echo
        if ! set_want "$nodes"; then
            echo "  cannot expand that node list -- no overlap check is possible"
        else
            echo "  running jobs holding them:"
            held=$(blocking_jobs "$id")
            if [[ -n "$held" ]]; then
                echo "$held"
            else
                echo "  none -- no running job holds any of these nodes"
            fi

            echo
            echo "  reservations covering them:"
            res=$(covering_reservations)
            if [[ -n "$res" ]]; then
                echo "$res"
            else
                echo "  none -- no reservation holds any of these nodes"
            fi
        fi
    fi

    echo
    squeue -o "$fmt" -j "$id" 2>/dev/null | column -t -s'|' | sed 's/^/  /'
    echo
done

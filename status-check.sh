#!/bin/bash
#
# Usage: status-check.sh [-t test] [-s] [pattern]
#
#   pattern  optional node-name filter. A bare string matches every node whose
#            name starts with it, so a rack prefix (dh01-rack01) covers the
#            whole rack. Shell globs (dh01-rack0[12]*, *node05) are honored as
#            written, so an explicit pattern can match anywhere in the name.
#            With no pattern, every node under results/ is reported.
#
#   -t, --test <pattern>
#            optional test filter, repeatable (-t dcgm -t allreduce). Unlike the
#            node pattern this does NOT append a `*`: benchmark names are
#            prefixes of each other (allreduce, allreduce-nonvlink), so an
#            implicit prefix match would quietly pull in the nonvlink variant
#            every time someone asked for allreduce. Match it as written and
#            spell the glob out -- `-t 'allreduce*'` for both, `-t '*nonvlink'`
#            for the nonvlink pair.
#
#            The pattern is matched against the job name AND against the full
#            column name, so `-t allreduce` selects every run of allreduce
#            (allreduce-run1..runN) while `-t allreduce-run2` selects the one
#            run. A pattern matching no active benchmark is an error rather
#            than an empty report -- with no output, a typo'd test name reads
#            exactly like a clean cluster.
#
#   -s, --summary
#            roll-up instead of the per-column report: one compressed node list
#            per status, for feeding to scancel/pdsh/scontrol. Reasons are
#            dropped -- this answers "which nodes" and the default report
#            answers "why".
#
#            Every node lands in exactly ONE list, under the worst status it
#            holds across the selected tests (FAIL > INCOMPLETE > RETRY >
#            NOT_RUN > DONE), so the lists are disjoint and a node cannot be
#            acted on twice. DONE therefore means every selected test passes,
#            not that some did.
#
#            Combines with -t, and the header names the tests the roll-up
#            covers: `-s -t allreduce` is a list of nodes judged on allreduce
#            alone, and an exported list that does not say so is one paste away
#            from draining nodes for a test they were never judged on.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"
jobs_dir="$home/jobs"

tests=()
summary=0
args=()
while (($#)); do
    case "$1" in
        -t|--test)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a test pattern" >&2; exit 1; }
            tests+=("$2"); shift 2 ;;
        -s|--summary) summary=1; shift ;;
        -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)         args+=("$1"); shift ;;
    esac
done

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

# Read active benchmark list from launch_job.sh
active_benchmarks=$(grep -E '^benchmarks=' "$home/actions/launch_job.sh" | head -1 | tr -d '"' | cut -d= -f2-)

# Build ordered job+run list matching what launch_job.sh actually tracks
declare -a columns  # each entry is "job" or "job-runN"

# Both names are offered to the pattern rather than stripping "-runN" off the
# column: the split is only reliable here, where the suffix was just built.
select_test() {
    local job="$1" col="$2" pat
    [[ ${#tests[@]} -eq 0 ]] && return 0
    for pat in "${tests[@]}"; do
        [[ "$job" == $pat || "$col" == $pat ]] && return 0
    done
    return 1
}

for job in $active_benchmarks; do
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || continue
    if grep -Fq "totalRuns" "$sbatch"; then
        totalRuns=$(grep -F totalRuns "$sbatch" | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        totalRuns=1
    fi

    if [[ "$totalRuns" -eq 1 ]]; then
        select_test "$job" "$job" && columns+=("$job")
    else
        for ((r=1; r<=totalRuns; r++)); do
            select_test "$job" "${job}-run${r}" && columns+=("${job}-run${r}")
        done
    fi
done

if [[ ${#columns[@]} -eq 0 ]]; then
    if [[ ${#tests[@]} -gt 0 ]]; then
        echo "No active benchmark matches: ${tests[*]}" >&2
        echo "Active benchmarks: $active_benchmarks" >&2
    else
        echo "No active benchmark has a job file under $jobs_dir" >&2
    fi
    exit 1
fi

## The verdict is derived from the log by verdict.sh on every run, not read from
## a marker the sbatch wrote. So this reports what the CURRENT gate makes of a
## result, which is the point -- a result that passed an older, looser gate is
## re-judged here rather than keeping its original DONE.
if [[ ! -f "$home/verdict.sh" ]]; then
    echo "ERROR: $home/verdict.sh is missing -- it carries the pass/fail rule for" >&2
    echo "       every job, and without it nothing can be judged." >&2
    exit 1
fi
source "$home/verdict.sh"

# Prior failed attempts archived by launch_job.sh as <col>.fail<N>.txt.
# A column with archives and no current file is queued for its next retry.
fail_count() {
    local node="$1" col="$2"
    ls "$results_dir/$node" 2>/dev/null | grep -cE "^${col}\.fail[0-9]+\.txt$"
}

# Newest archive for a column, by the numeric suffix rather than by mtime --
# the suffix is what launch_job.sh increments, and an rsync or a restore can
# reorder mtimes without changing which attempt was last.
last_fail_file() {
    local node="$1" col="$2" n
    n=$(ls "$results_dir/$node" 2>/dev/null \
        | sed -n "s/^${col}\.fail\([0-9]\+\)\.txt$/\1/p" | sort -n | tail -1)
    [[ -n "$n" ]] && printf '%s' "$results_dir/$node/${col}.fail${n}.txt"
}

matched=0
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] && matched=1 && break
done
if [[ "$matched" -eq 0 ]]; then
    # args[0], not $1 -- $1 is whichever flag came first once -t/-s are in play.
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi

# Worst status a node holds decides its summary bucket. Ranked so the roll-up
# lists stay disjoint: a node failing one test and missing another is a FAIL,
# because that is the state that has to be acted on first.
declare -A rank=([FAIL]=5 [INCOMPLETE]=4 [RETRY]=3 [NOT_RUN]=2 [DONE]=1)
declare -A worst  # node -> worst status seen across the selected columns

# One line per node per column on stdout, and the per-node roll-up in `worst`.
# Only the default path pipes this into dshbak: a pipeline runs the loop in a
# subshell, so piping in summary mode would build `worst` in a child and leave
# the parent printing empty lists.
scan() {
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node=$(basename "$node_dir")
    for col in "${columns[@]}"; do
        file="$results_dir/$node/${col}.txt"
        # Not $(verdict ...) -- a subshell would lose the reason. See verdict().
        verdict "$(verdict_job_name "$col")" "$file"
        status="$VERDICT_STATUS"
        reason="$VERDICT_REASON"
        fails=$(fail_count "$node" "$col")

        ## NOT_RUN means "no result file", which covers two states that are
        ## nothing alike: never attempted, and attempted-failed-archived-and
        ## resubmitted. launch_job.sh moves a rejected result to <col>.failN.txt
        ## BEFORE submitting the retry, so between the archive and the new job
        ## writing its first byte the column has no file at all -- and the node
        ## reported `NOT_RUN (fails: 1)`, which reads as a contradiction: it
        ## says the job never ran and that it failed once.
        ##
        ## Judge the newest archive instead. That turns the line into RETRY plus
        ## the reason the last attempt was rejected, which is the question
        ## anyone reading this actually has. NOT_RUN then keeps a single
        ## meaning: no attempt has ever been made.
        if [[ "$status" == "NOT_RUN" && "$fails" -gt 0 ]]; then
            prev=$(last_fail_file "$node" "$col")
            verdict "$(verdict_job_name "$col")" "$prev"
            status=RETRY
            ## DONE here is not a contradiction either: the archive was rejected
            ## by the gate in force when it ran, and a since-loosened gate now
            ## accepts it. Say so rather than printing RETRY with no reason.
            if [[ "$VERDICT_STATUS" == "DONE" ]]; then
                reason="prior attempt passes the current gate"
            else
                reason="$VERDICT_REASON"
            fi
        fi
        # A passing column is done -- how many tries it took is history, not
        # status, and annotating it splits DONE nodes into dshbak groups that
        # all mean the same thing. The archives stay on disk either way, and
        # the daily CSV still carries the per-job counts.
        [[ "$status" == "DONE" ]] && fails=0

        if [[ "$summary" -eq 1 ]]; then
            prior="${worst[$node]:-}"
            if [[ -z "$prior" || "${rank[$status]}" -gt "${rank[$prior]}" ]]; then
                worst["$node"]="$status"
            fi
            continue
        fi

        # The reason is part of the line on purpose. dshbak groups identical
        # lines, so nodes failing the same way collapse into one block and a
        # single node failing differently stands out -- the same reason
        # health-check.sh groups by failure signature rather than by check.
        line="$node: $col: $status"
        [[ "$status" != "DONE" && "$status" != "NOT_RUN" && -n "$reason" ]] && line+=" -- $reason"
        [[ "$fails" -gt 0 ]] && line+=" (fails: $fails)"
        echo "$line"
    done
done
}

if [[ "$summary" -ne 1 ]]; then
    scan | sort | dshbak -c
    exit 0
fi

# Ranges rather than a bare comma list, so a bucket can be pasted straight into
# scancel/pdsh -w. Falls back to the raw list where scontrol is not on PATH,
# which is still valid input to most of the same tools.
compress() {
    local out
    out=$(scontrol show hostlistsorted "$1" 2>/dev/null)
    [[ -n "$out" ]] && printf '%s' "$out" || printf '%s' "$1"
}

plural() { [[ "$1" -eq 1 ]] && printf 'node' || printf 'nodes'; }

scan

# Name the tests up front. A roll-up carries no column names, so without this
# a list produced by -t reads as a verdict on the whole benchmark set.
if [[ ${#tests[@]} -gt 0 ]]; then
    echo "SUMMARY — judged on: ${columns[*]}"
else
    echo "SUMMARY — judged on all ${#columns[@]} active columns"
fi
echo

bucket() {
    local status="$1" note="$2" list="" n=0 node
    # Sorted, because the fallback path prints this list as-is and associative
    # array order is a hash order -- the same cluster would export the same
    # nodes in a different order on every run, and no diff of two runs would
    # mean anything.
    while IFS= read -r node; do
        [[ "${worst[$node]}" == "$status" ]] && { list+="${list:+,}$node"; ((n++)); }
    done < <(printf '%s\n' "${!worst[@]}" | sort)
    [[ "$n" -eq 0 ]] && return
    printf '%s — %d %s (%s)\n' "$status" "$n" "$(plural "$n")" "$note"
    printf '%s\n\n' "$(compress "$list")"
}

# Failures first: on an export the actionable list is the one being reached for.
bucket FAIL       "ran and was rejected by the current gate"
bucket INCOMPLETE "died before writing an end marker"
bucket RETRY      "last attempt rejected, resubmitted, nothing written yet"
bucket NOT_RUN    "no attempt has ever been made"
bucket DONE       "every selected test passes the current gate"

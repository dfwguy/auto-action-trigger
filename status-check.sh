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
#            NOT_RUN > RUNNING > DONE), so the lists are disjoint and a node
#            cannot be acted on twice. DONE therefore means every selected test
#            passes, not that some did.
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

# The slurm client tools are behind a module, so they are on PATH in a login
# shell and absent when this is run from cron, from a trigger, or over ssh with
# a command argument. Load it the same way launch_job.sh does, but only when
# the tools are actually missing -- an operator who already has slurm loaded,
# or a site that puts it in /usr/bin, keeps whatever they have. `module` is a
# shell function that only exists after modules.sh is sourced, so both halves
# are guarded and neither is allowed to be fatal: unlike launch_job.sh, which
# exits rather than misreport a node as healthy, this script still has a report
# to give from the files alone. It degrades in exactly two named places --
# node_running below and compress() at the bottom.
if ! command -v squeue >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi

# Nodes with one of our batches actually executing right now.
#
# verdict() reports "no end marker" as INCOMPLETE, which is correct for
# launch_job.sh -- it only judges a node after squeue has told it nothing is
# queued or running there, so a missing marker really does mean the job died.
# This script has no such guard: it reads result files whenever an operator
# runs it, and sbatch is invoked with --output=<result file>, so a benchmark
# that is mid-run has a partial file and no marker. Reported verbatim, every
# in-flight job on the cluster reads as `died before finishing` -- and
# INCOMPLETE outranks everything but FAIL, so it takes the node's whole
# roll-up with it.
#
# One squeue call for the cluster, not one per node: the per-node query is the
# same table filtered N times, and on a full rack that is hundreds of forks to
# answer a question a single listing already answers. Jobs are matched by the
# `bringup-<node>` name launch_job.sh submits under, which is also how it finds
# its own work. RUNNING only -- a queued job has not been given a node yet and
# has written no file, so its columns are NOT_RUN or RETRY and never reach the
# reclassification below.
declare -A node_running
if command -v squeue >/dev/null 2>&1; then
    while IFS='|' read -r name state; do
        [[ "$state" == "RUNNING" && "$name" == bringup-* ]] || continue
        node_running["${name#bringup-}"]=1
    done < <(squeue -h -o '%j|%T' 2>/dev/null)
else
    # Same posture as compress(): the report still works off the files alone,
    # it just cannot separate running from dead. Say so once rather than
    # printing "died before finishing" over jobs nobody has checked on.
    echo "NOTE: squeue is not on PATH even after 'module load slurm' -- a running" >&2
    echo "      job cannot be told from a dead one, so both report as INCOMPLETE." >&2
fi

# The column a running batch is currently writing, or empty.
#
# squeue knows a job is running on the node but not which benchmark it is: all
# of them share the one `bringup-<node>` name so --dependency=singleton can
# serialize them. The file system knows. sbatch truncates its --output at job
# start, and singleton means no earlier benchmark for this node is still
# running, so the live job's file is the most recently touched result file on
# the node -- newest even when it has not yet written its first byte, because
# every other file was last written by a job that had already exited.
#
# Archives are excluded: a .fail<N>.txt is created by launch_job.sh's `mv` at
# submit time, which can leave it newer than the file the new job is writing.
live_column() {
    local node="$1" f
    f=$(ls -t "$results_dir/$node"/*.txt 2>/dev/null | grep -v '\.fail[0-9]\+\.txt$' | head -1)
    [[ -n "$f" ]] || return
    f="${f##*/}"
    printf '%s' "${f%.txt}"
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
#
# RUNNING sits above DONE and below everything else. Above DONE because a node
# still working is not a node that passed, and a DONE list is read as "finished
# and good" -- an in-flight benchmark can still fail. Below NOT_RUN because a
# node with untouched columns has work outstanding whether or not one job
# happens to be executing at the instant the report was run.
declare -A rank=([FAIL]=6 [INCOMPLETE]=5 [RETRY]=4 [NOT_RUN]=3 [RUNNING]=2 [DONE]=1)
declare -A worst  # node -> worst status seen across the selected columns

# One line per node per column on stdout, and the per-node roll-up in `worst`.
# Only the default path pipes this into dshbak: a pipeline runs the loop in a
# subshell, so piping in summary mode would build `worst` in a child and leave
# the parent printing empty lists.
scan() {
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node=$(basename "$node_dir")
    # Once per node, and only for a node squeue placed a live job on -- the
    # lookup is a directory listing, and running it per column would repeat it
    # for every benchmark on every node to answer one question per node.
    live=""
    [[ -n "${node_running[$node]:-}" ]] && live=$(live_column "$node")
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
        ## The one column on this node that a live batch is writing is not a
        ## job that died before its last line -- it has not reached its last
        ## line yet. Every OTHER incomplete column on the same node keeps its
        ## INCOMPLETE: singleton runs these one at a time, so a marker-less
        ## file that is not the one being written was left by a job that has
        ## already exited.
        if [[ "$status" == "INCOMPLETE" && -n "$live" && "$col" == "$live" ]]; then
            status=RUNNING
            reason="job is on the node now, no verdict until it finishes"
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
    # dshbak (from pdsh) only groups the lines -- every line it would print is
    # already on stdout without it. Guarded because a missing dshbak takes the
    # whole report down silently: the shell writes `dshbak: command not found`
    # to stderr, the pipeline still exits 0, and stdout is empty. On a cluster
    # that reads as "no nodes match", which is the same failure this script was
    # just taught to stop making about running jobs. Print ungrouped instead
    # and say why.
    if command -v dshbak >/dev/null 2>&1; then
        scan | sort | dshbak -c
    else
        echo "NOTE: dshbak is not on PATH (it ships with pdsh) -- printing one" >&2
        echo "      line per node instead of grouping identical statuses." >&2
        scan | sort
    fi
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
bucket INCOMPLETE "no end marker and no job on the node -- died before finishing"
bucket RETRY      "last attempt rejected, resubmitted, nothing written yet"
bucket NOT_RUN    "no attempt has ever been made"
bucket RUNNING    "a benchmark is executing now -- not yet judged"
bucket DONE       "every selected test passes the current gate"

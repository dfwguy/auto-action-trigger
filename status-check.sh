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
source "$home/settings.sh"
results_dir="$home/results"
jobs_dir="$JOBS_DIR"

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

# Burn-in columns appear only while RUN_BURNIN is on, or they read NOT_RUN
# forever. See docs/operations.md#status-and-reporting.
active_benchmarks="$BENCHMARKS"
setting_enabled "$RUN_BURNIN" && active_benchmarks="$BENCHMARKS $BURNIN"

declare -a columns  # each entry is "job" or "job-runN"

# Job name and full column are both offered to the pattern; the "-runN" split is
# only reliable here, where the suffix was just built.
select_test() {
    local job="$1" col="$2" pat
    [[ ${#tests[@]} -eq 0 ]] && return 0
    for pat in "${tests[@]}"; do
        ## Unquoted RHS on purpose: -t globs are the feature, and quoting makes
        ## it a plain string compare. Nothing is appended, so a -t without a
        ## glob still matches only the literal name.
        # shellcheck disable=SC2053
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

## Verdicts are derived from the log on every read, so a result on disk is
## re-judged by the current gate. See docs/operations.md#status-and-reporting.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
source "$PARSERS_DIR/verdict.sh"

# Newest <col>.fail<N>.txt, launch_job.sh's archive of a rejected attempt.
last_fail_file() {
    last_archive_file "$1" "$2" fail
}

# Same for either suffix; .prev<N>.txt is a PASSING result moved aside by
# `launch_job.sh --all`, never counted as a failure. Selected by numeric suffix,
# not mtime: an rsync or restore reorders mtimes, the suffix is authoritative.
last_archive_file() {
    local node="$1" col="$2" kind="$3" n
    n=$(ls "$results_dir/$node" 2>/dev/null \
        | sed -n "s/^${col}\.${kind}\([0-9]\+\)\.txt$/\1/p" | sort -n | tail -1)
    [[ -n "$n" ]] && printf '%s' "$results_dir/$node/${col}.${kind}${n}.txt"
}

# The slurm tools live behind a module and are absent from cron/ssh/trigger
# shells. Nothing here is fatal: unlike launch_job.sh, this script still has a
# report to give from the files alone, degrading in node_running and compress().
if ! command -v squeue >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi

# Nodes with one of our batches executing right now, so a mid-run partial file
# is not reported as INCOMPLETE. See docs/operations.md#status-and-reporting.
#
# One squeue call for the cluster, not one per node. RUNNING only -- a queued
# job has written no file, so its columns are NOT_RUN or RETRY anyway.
declare -A node_running
if command -v squeue >/dev/null 2>&1; then
    while IFS='|' read -r name state; do
        [[ "$state" == "RUNNING" ]] || continue
        case "$name" in
            bringup-*) node_running["${name#bringup-}"]=1 ;;
            burnin-*)  node_running["${name#burnin-}"]=1 ;;
        esac
    done < <(squeue -h -o '%j|%T' 2>/dev/null)
else
    # Say it once rather than printing "died before finishing" over live jobs.
    echo "NOTE: squeue is not on PATH even after 'module load slurm' -- a running" >&2
    echo "      job cannot be told from a dead one, so both report as INCOMPLETE." >&2
fi

# The column a running batch is currently writing, or empty. squeue knows the
# node but not the benchmark; the file system does. sbatch truncates --output at
# job start and every benchmark is --exclusive, so the live job's file is the
# newest result file on the node even before it writes its first byte.
#
# Archives are excluded: launch_job.sh `mv`s them at submit time, which can
# leave one newer than the file the new job is writing.
live_column() {
    local node="$1" f
    ## `ls -t` is the point: a glob expands in collating order, so newest-first
    ## would cost a stat per file, and the exclusion must follow the ordering.
    ## Every name here is a BENCHMARKS entry plus a fixed suffix, so the odd
    ## filenames SC2010 guards against cannot arise.
    # shellcheck disable=SC2010
    f=$(ls -t "$results_dir/$node"/*.txt 2>/dev/null | grep -vE '\.(fail|prev)[0-9]+\.txt$' | head -1)
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

# Worst status a node holds decides its summary bucket, so the roll-up lists
# stay disjoint. RUNNING sits above DONE (still working is not passed) and below
# NOT_RUN (untouched columns are work outstanding either way).
# See docs/operations.md#status-and-reporting.
declare -A rank=([FAIL]=6 [INCOMPLETE]=5 [RETRY]=4 [NOT_RUN]=3 [RUNNING]=2 [DONE]=1)
declare -A worst  # node -> worst status seen across the selected columns

# One line per node per column on stdout, plus the per-node roll-up in `worst`.
# Never pipe this in summary mode: a pipeline runs the loop in a subshell and
# `worst` would be built in a child.
scan() {
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node=$(basename "$node_dir")
    # Once per node, not per column -- the lookup is a directory listing.
    live=""
    [[ -n "${node_running[$node]:-}" ]] && live=$(live_column "$node")
    for col in "${columns[@]}"; do
        file="$results_dir/$node/${col}.txt"
        # Not $(verdict ...) -- a subshell would lose the reason. See verdict().
        verdict "$(verdict_job_name "$col")" "$file"
        status="$VERDICT_STATUS"
        reason="$VERDICT_REASON"

        ## launch_job.sh archives a rejected result before submitting the retry,
        ## so the column has no file at all in between. Judge the newest archive
        ## and call it RETRY, leaving NOT_RUN one meaning: never attempted.
        if [[ "$status" == "NOT_RUN" ]] &&
             prev=$(last_fail_file "$node" "$col") && [[ -n "$prev" ]]; then
            verdict "$(verdict_job_name "$col")" "$prev"
            status=RETRY
            ## Not a contradiction: the gate has been loosened since the archive
            ## was rejected. Say so rather than printing RETRY with no reason.
            if [[ "$VERDICT_STATUS" == "DONE" ]]; then
                reason="prior attempt passes the current gate"
            else
                reason="$VERDICT_REASON"
            fi
        ## Same gap from `launch_job.sh --all`, which archives a PASSING result
        ## as <col>.prevN.txt -- no current file and no failures either.
        elif [[ "$status" == "NOT_RUN" ]] &&
             prev=$(last_archive_file "$node" "$col" prev) && [[ -n "$prev" ]]; then
            verdict "$(verdict_job_name "$col")" "$prev"
            status=RETRY
            reason="re-queued by --all; previous result: $VERDICT_STATUS"
        fi
        ## Only the column being written now. --exclusive runs these one at a
        ## time, so any OTHER marker-less file was left by a job that has exited.
        if [[ "$status" == "INCOMPLETE" && -n "$live" && "$col" == "$live" ]]; then
            status=RUNNING
            reason="job is on the node now, no verdict until it finishes"
        fi

        if [[ "$summary" -eq 1 ]]; then
            prior="${worst[$node]:-}"
            if [[ -z "$prior" || "${rank[$status]}" -gt "${rank[$prior]}" ]]; then
                worst["$node"]="$status"
            fi
            continue
        fi

        # The reason is on the line so dshbak collapses nodes failing the same
        # way. No attempt count: it is per node and would split one block into a
        # block per count. See docs/operations.md#status-and-reporting.
        line="$node: $col: $status"
        [[ "$status" != "DONE" && "$status" != "NOT_RUN" && -n "$reason" ]] && line+=" -- $reason"
        echo "$line"
    done
done
}

# Paused means the report stops moving. On stderr so it survives -s being piped
# and cannot land inside a node list pasted into scancel.
if setting_enabled "$PAUSE_JOBS"; then
    echo "NOTE: PAUSE_JOBS=$PAUSE_JOBS in ${SETTINGS_FILE##*/} -- no benchmarks are" >&2
    echo "      being submitted, so nothing below will change until it is set to no." >&2
fi

if [[ "$summary" -ne 1 ]]; then
    # dshbak (from pdsh) only groups lines. Guarded because a missing dshbak
    # empties stdout while the pipeline still exits 0 -- silently identical to
    # "no nodes match". Print ungrouped and say why instead.
    if command -v dshbak >/dev/null 2>&1; then
        scan | sort | dshbak -c
    else
        echo "NOTE: dshbak is not on PATH (it ships with pdsh) -- printing one" >&2
        echo "      line per node instead of grouping identical statuses." >&2
        scan | sort
    fi
    exit 0
fi

# Ranges rather than a bare comma list, for pasting into scancel/pdsh -w. The
# raw list is still valid input to most of the same tools, so falling back is ok.
compress() {
    local out
    out=$(scontrol show hostlistsorted "$1" 2>/dev/null)
    [[ -n "$out" ]] && printf '%s' "$out" || printf '%s' "$1"
}

plural() { [[ "$1" -eq 1 ]] && printf 'node' || printf 'nodes'; }

scan

# Name the tests up front, or a -t-scoped list reads as a verdict on the whole
# benchmark set. See docs/operations.md#status-and-reporting.
if [[ ${#tests[@]} -gt 0 ]]; then
    echo "SUMMARY — judged on: ${columns[*]}"
else
    echo "SUMMARY — judged on all ${#columns[@]} active columns"
fi
echo

bucket() {
    local status="$1" note="$2" list="" n=0 node
    # Sorted: the fallback path prints the list as-is, and associative array
    # order is hash order, so two runs of the same cluster would not diff.
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

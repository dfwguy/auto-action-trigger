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
#            optional test filter, repeatable (-t dcgmi-r3 -t fio). Unlike the
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
#
#   --no-cache
#            judge every node from its files, ignoring results/.result_cache.*.
#            A cached report is the report you would have got anyway; reach for
#            this when you suspect the cache rather than the gate. Deleting the
#            cache files does the same, and they are safe to remove at any time.
#            See docs/operations.md#the-verdict-cache.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

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
        --no-cache) export SCAN_CACHE=0; shift ;;
        -h|--help) sed -n '2,49p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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

# Judges every cell, in parallel worker processes.
# See docs/operations.md#how-a-report-is-produced.
# shellcheck source=/dev/null
source "$home/verdict-scan.sh"

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
#
# A file, not a variable: the scan runs in workers, and a large fleet's running
# list should not go through exec once per worker.
running_file=$(mktemp) || exit 1
trap 'rm -f "$running_file"' EXIT
if command -v squeue >/dev/null 2>&1; then
    while IFS='|' read -r name state; do
        [[ "$state" == "RUNNING" ]] || continue
        case "$name" in
            bringup-*) printf '%s\n' "${name#bringup-}" ;;
            burnin-*)  printf '%s\n' "${name#burnin-}" ;;
        esac
    done < <(squeue -h -o '%j|%T' 2>/dev/null) > "$running_file"
else
    # Say it once rather than printing "died before finishing" over live jobs.
    echo "NOTE: squeue is not on PATH even after 'module load slurm' -- a running" >&2
    echo "      job cannot be told from a dead one, so both report as INCOMPLETE." >&2
fi

declare -a nodes
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node_dir="${node_dir%/}"
    ## Not basename: that is a fork per node for what expansion does free.
    nodes+=("${node_dir##*/}")
done
if [[ ${#nodes[@]} -eq 0 ]]; then
    # args[0], not $1 -- $1 is whichever flag came first once -t/-s are in play.
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi

# Exported, not passed, so node names are all that is on the command line and
# xargs can chunk them. See docs/operations.md#how-a-report-is-produced.
export SCAN_RESULTS_DIR="$results_dir"
export SCAN_COLUMNS="${columns[*]}"
export SCAN_RUNNING_FILE="$running_file"
export SCAN_ARCHIVES=1     # RETRY: this report distinguishes it from NOT_RUN
export SCAN_METRICS=0      # no numbers in this report, only statuses

# Worst status a node holds decides its summary bucket, so the roll-up lists
# stay disjoint. RUNNING sits above DONE (still working is not passed) and below
# NOT_RUN (untouched columns are work outstanding either way).
# See docs/operations.md#status-and-reporting.
RANKS='FAIL 6 INCOMPLETE 5 RETRY 4 NOT_RUN 3 RUNNING 2 DONE 1'

# Scan rows to report lines. The reason is on the line so dshbak collapses
# nodes failing the same way; no attempt count, which would split one block into
# one per count. In awk because this is tens of thousands of rows and no state.
# See docs/operations.md#status-and-reporting.
report_lines() {
    awk -F"$SCAN_FS" '{
        line = $1 ": " $2 ": " $3
        if ($3 != "DONE" && $3 != "NOT_RUN" && $4 != "") line = line " -- " $4
        print line
    }'
}

# Worst status per node, for the summary buckets. In awk because the scan runs
# in children and cannot build state here.
worst_per_node() {
    awk -F"$SCAN_FS" -v ranks="$RANKS" -v ofs="$SCAN_FS" '
        BEGIN { n = split(ranks, a, " "); for (i = 1; i < n; i += 2) rank[a[i]] = a[i + 1] }
        !($1 in best) || rank[$3] > rank[best[$1]] { best[$1] = $3 }
        END { for (node in best) print node ofs best[node] }'
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
        scan_fleet "${nodes[@]}" | report_lines | sort | dshbak -c
    else
        echo "NOTE: dshbak is not on PATH (it ships with pdsh) -- printing one" >&2
        echo "      line per node instead of grouping identical statuses." >&2
        scan_fleet "${nodes[@]}" | report_lines | sort
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

# One sorted pass, not one per bucket: compress()'s fallback prints the list as
# built, so the order has to be node order.
declare -A bucket_nodes bucket_count
while IFS="$SCAN_FS" read -r node status; do
    bucket_nodes["$status"]+="${bucket_nodes[$status]:+,}$node"
    (( bucket_count["$status"]++ ))
done < <(scan_fleet "${nodes[@]}" | worst_per_node | sort)

# Name the tests up front, or a -t-scoped list reads as a verdict on the whole
# benchmark set. See docs/operations.md#status-and-reporting.
if [[ ${#tests[@]} -gt 0 ]]; then
    echo "SUMMARY — judged on: ${columns[*]}"
else
    echo "SUMMARY — judged on all ${#columns[@]} active columns"
fi
echo

bucket() {
    local status="$1" note="$2" n="${bucket_count[$1]:-0}"
    [[ "$n" -eq 0 ]] && return
    printf '%s — %d %s (%s)\n' "$status" "$n" "$(plural "$n")" "$note"
    printf '%s\n\n' "$(compress "${bucket_nodes[$status]}")"
}

# Failures first: on an export the actionable list is the one being reached for.
bucket FAIL       "ran and was rejected by the current gate"
bucket INCOMPLETE "no end marker and no job on the node -- died before finishing"
bucket RETRY      "last attempt rejected, resubmitted, nothing written yet"
bucket NOT_RUN    "no attempt has ever been made"
bucket RUNNING    "a benchmark is executing now -- not yet judged"
bucket DONE       "every selected test passes the current gate"

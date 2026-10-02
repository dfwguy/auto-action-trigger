#!/bin/bash
#
# Usage: report_job-status.sh [-t test] [-s] [--sort-by-hostname] [pattern]
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
#            per status, for feeding to scancel/clush/pdsh/scontrol. Reasons are
#            dropped -- this answers "which nodes" and the default report
#            answers "why".
#
#            Every node lands in exactly ONE list, under the worst status it
#            holds across the selected tests (FAIL > INCOMPLETE > NOT_RUN >
#            RERUNNING > RUNNING > DONE), so the lists are disjoint and a node
#            cannot be acted on twice. DONE therefore means every selected test
#            passes, not that some did.
#
#            Combines with -t, and the header names the tests the roll-up
#            covers: `-s -t allreduce` is a list of nodes judged on allreduce
#            alone, and an exported list that does not say so is one paste away
#            from draining nodes for a test they were never judged on.
#
#   --sort-by-hostname
#            order the report by node rather than by test. The default walks the
#            benchmark columns in the order they are configured and prints one
#            section per test, so a test's whole fleet reads as one block; this
#            sorts every row by node name instead, so one node's columns sit
#            together and the tests are interleaved.
#
#   --no-cache
#            judge every node from its files, ignoring results/.result_cache.*.
#            A cached report is the report you would have got anyway; reach for
#            this when you suspect the cache rather than the gate. Deleting the
#            cache files does the same, and they are safe to remove at any time.
#            See docs/explanation/verdicts-and-the-cache.md#the-verdict-cache.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
source "$home/fanout.sh"
results_dir="$RESULTS_DIR"
jobs_dir="$JOBS_DIR"

tests=()
summary=0
by_node=0
args=()
while (($#)); do
    case "$1" in
        -t|--test)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a test pattern" >&2; exit 1; }
            tests+=("$2"); shift 2 ;;
        -s|--summary) summary=1; shift ;;
        --sort-by-hostname) by_node=1; shift ;;
        --no-cache) export SCAN_CACHE=0; shift ;;
        -h|--help) sed -n '2,56p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)         args+=("$1"); shift ;;
    esac
done

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

# BURNIN never expands into per-run columns here -- it is reported as one
# accumulated-hours line instead, printed separately below.
# See docs/reference/settings.md#burn-in.
active_benchmarks="$BENCHMARKS"

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

# Shown whenever burn-in is on and nothing about -t rules it out -- the
# accumulated line is one job (mnubergemm) or several, so it is offered to
# select_test once per BURNIN job rather than as a single fixed name.
show_burnin=0
if setting_enabled "$RUN_BURNIN" && [[ -n "${BURNIN// /}" ]]; then
    if [[ ${#tests[@]} -eq 0 ]]; then
        show_burnin=1
    else
        for job in $BURNIN; do
            select_test "$job" "$job" && { show_burnin=1; break; }
        done
    fi
fi

for job in $active_benchmarks; do
    ## See docs/explanation/sequencing.md#host-launched-jobs.
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || sbatch="$jobs_dir/$job.sh"
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

if [[ ${#columns[@]} -eq 0 && "$show_burnin" -eq 0 ]]; then
    if [[ ${#tests[@]} -gt 0 ]]; then
        echo "No active benchmark matches: ${tests[*]}" >&2
        echo "Active benchmarks: $active_benchmarks" >&2
    else
        echo "No active benchmark has a job file under $jobs_dir" >&2
    fi
    exit 1
fi

## Verdicts are derived from the log on every read, so a result on disk is
## re-judged by the current gate. See docs/reference/scripts.md.
if [[ ! -f "$PARSERS_DIR/verdict.sh" ]]; then
    echo "ERROR: $PARSERS_DIR/verdict.sh is missing -- it carries the pass/fail rule" >&2
    echo "       for every job, and without it nothing can be judged." >&2
    echo "       PARSERS=$PARSERS, from ${SETTINGS_FILE:-<no settings file found>}." >&2
    exit 1
fi
source "$PARSERS_DIR/verdict.sh"

# Judges every cell, in parallel worker processes.
# See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
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
# is not reported as INCOMPLETE. See docs/reference/scripts.md.
#
# One squeue call for the cluster, not one per node. RUNNING only -- a queued
# job has written no file, so its columns are judged from the archive it left.
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

declare -a nodes excluded
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] || continue
    node_dir="${node_dir%/}"
    ## Not basename: that is a fork per node for what expansion does free.
    node="${node_dir##*/}"
    ## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
    node_out_of_reporting "$results_dir" "$node" && { excluded+=("$node"); continue; }
    nodes+=("$node")
done
## Named rather than dropped in silence: a row that vanishes with no reason is
## indistinguishable from a node nobody ever registered.
if [[ ${#excluded[@]} -gt 0 ]]; then
    echo "NOTE: left out, not compute nodes: ${excluded[*]}" >&2
fi
## A node that has stopped cycling still has rows, and they are the last thing
## written rather than what is true now.
## See docs/explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means.
declare -a silent
for node in "${nodes[@]}"; do
    heartbeat_stale "$results_dir" "$node" && silent+=("$node")
done
if [[ ${#silent[@]} -gt 0 ]]; then
    echo "NOTE: ${#silent[@]} node(s) have not cycled in ${HEARTBEAT_STALE_MINUTES}m, so their rows are the last thing written rather than what is true now: ${silent[*]}" >&2
    echo "      Their timers are not firing. ./check_trigger-log.sh section 0 is the fleet view;" >&2
    echo "      results/<node>/arm.log is what the watchdog heard back from each." >&2
fi

if [[ ${#nodes[@]} -eq 0 ]]; then
    # args[0], not $1 -- $1 is whichever flag came first once -t/-s are in play.
    echo "No nodes under $results_dir match '${args[0]:-*}'" >&2
    exit 1
fi

# Exported, not passed, so node names are all that is on the command line and
# xargs can chunk them. See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
export SCAN_RESULTS_DIR="$results_dir"
export SCAN_COLUMNS="${columns[*]}"
export SCAN_RUNNING_FILE="$running_file"
export SCAN_ARCHIVES=1     # judge the archive a re-queued column left behind
export SCAN_METRICS=0      # no numbers in this report, only statuses

# Worst status a node holds decides its summary bucket, so the roll-up lists
# stay disjoint. RERUNNING sits below NOT_RUN: a column re-queued off a pass is
# not work anyone is waiting on, where one never attempted is.
# See docs/reference/scripts.md.
RANKS='FAIL 6 INCOMPLETE 5 NOT_RUN 4 RERUNNING 3 RUNNING 2 DONE 1'

# Scan rows to report lines. The reason is on the line so the grouping collapses
# nodes failing the same way; no attempt count, which would split one block into
# one per count. In awk because this is tens of thousands of rows and no state.
# See docs/reference/scripts.md.
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

# One line per node: "<node>: burn-in: <N>H/<BURNIN_HOURS>H". Not through
# scan_fleet/report_lines -- burnin_hours_cell sums across every BURNIN job
# and every run of each, which is not one column's verdict. See
# docs/explanation/burn-in-waveform.md.
print_burnin_lines() {
    local node
    for node in "${nodes[@]}"; do
        printf '%s: burn-in: %s\n' "$node" "$(burnin_hours_cell "$node")"
    done
}

# Paused means the report stops moving. On stderr so it survives -s being piped
# and cannot land inside a node list pasted into scancel.
if setting_disabled "$RUN_JOBS"; then
    echo "NOTE: RUN_JOBS=$RUN_JOBS in ${SETTINGS_FILE##*/} -- no benchmarks are" >&2
    echo "      being submitted, so nothing below will change until it is set to yes." >&2
fi

if [[ "$summary" -ne 1 ]]; then
    # clubak (ClusterShell) or dshbak (pdsh) only groups lines. Guarded because
    # a missing one empties stdout while the pipeline still exits 0 -- silently
    # identical to "no nodes match". Print ungrouped and say why instead.
    if bak_resolve; then
        group() { bak; }
    else
        echo "NOTE: neither clubak (ships with clush) nor dshbak (ships with pdsh)" >&2
        echo "      is on PATH -- printing one line per node instead of grouping" >&2
        echo "      identical statuses. Install ClusterShell to get the grouped form." >&2
        group() { cat; }
    fi

    if [[ "$by_node" -eq 1 ]]; then
        scan_fleet "${nodes[@]}" | report_lines | sort | group
        [[ "$show_burnin" -eq 1 ]] && print_burnin_lines | sort | group
        exit 0
    fi

    ## One scan split per column, then one invocation per test: the grouping
    ## tool orders its own output, so test order cannot come from sorting the
    ## rows. See docs/reference/scripts.md#the-order-of-the-report.
    scan_dir=$(mktemp -d) || exit 1
    trap 'rm -f "$running_file"; rm -rf "$scan_dir"' EXIT
    scan_fleet "${nodes[@]}" |
        awk -F"$SCAN_FS" -v dir="$scan_dir" '{ print > (dir "/" $2) }'
    rule=$(printf '%*s' 60 '' | tr ' ' '*')
    for col in "${columns[@]}"; do
        ## A column nothing has a row for is skipped, not printed empty.
        [[ -s "$scan_dir/$col" ]] || continue
        ## A banner per test: the grouping tool prints its own rules between
        ## blocks, so without one the sections run together and the report
        ## reads as the single list it used to be.
        printf '%s\n%s\n%s\n' "$rule" "$col" "$rule"
        report_lines < "$scan_dir/$col" | sort | group
        echo
    done
    if [[ "$show_burnin" -eq 1 ]]; then
        printf '%s\n%s\n%s\n' "$rule" "burn-in" "$rule"
        print_burnin_lines | sort | group
        echo
    fi
    exit 0
fi

# Ranges rather than a bare comma list, for pasting into scancel/clush -w. The
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
# benchmark set. See docs/reference/scripts.md.
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
bucket NOT_RUN    "no attempt has ever been made"
bucket RERUNNING  "a passing result was re-queued -- nothing written yet"
bucket RUNNING    "a benchmark is executing now -- not yet judged"
bucket DONE       "every selected test passes the current gate"

# Not a rank bucket: an hour fraction has no place in FAIL..DONE, and grouping
# by identical fraction is still one compressed list per value, same as above.
if [[ "$show_burnin" -eq 1 ]]; then
    declare -A burnin_bucket_nodes
    for node in "${nodes[@]}"; do
        v=$(burnin_hours_cell "$node")
        burnin_bucket_nodes["$v"]+="${burnin_bucket_nodes[$v]:+,}$node"
    done
    echo "BURN-IN"
    echo
    while IFS= read -r v; do
        printf '%s\n%s\n\n' "$v" "$(compress "${burnin_bucket_nodes[$v]}")"
    done < <(printf '%s\n' "${!burnin_bucket_nodes[@]}" | sort)
fi

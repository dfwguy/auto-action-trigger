#!/bin/bash
#
# Reports per-node benchmark status and performance metrics.
# Rows: nodes  |  Columns: per-job status + extracted metric (per run)
# Prints an aligned table to the screen and saves the same rows as
# $home/reports/report-YYYY-MM-DD_HH-MM-SS.csv

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"
jobs_dir="$home/jobs"
report_dir="$home/reports"
report_file="$report_dir/report-$(date '+%Y-%m-%d_%H-%M-%S').csv"

mkdir -p "$report_dir"

# ── Metric extraction ─────────────────────────────────────────────────────────
# Returns a single numeric value (or empty) for a completed result file.

extract_metric() {
    local job="$1" file="$2"
    case "$job" in
        hpl)
            # WC summary line: T/V N NB P Q Time Gflops (per_GPU)
            grep -E '^WC' "$file" 2>/dev/null | awk '{print $7}' | head -1
            ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink)
            # Find largest message size actually run, return out-of-place busbw
            awk '$1 ~ /^[0-9]+$/ {print}' "$file" 2>/dev/null | sort -k1,1n | tail -1 | awk '{print $8}'
            ;;
        nvbandwidth)
            # Lowest SUM across the requested test cases -- the weakest path
            grep -E '^SUM ' "$file" 2>/dev/null | awk '{print $NF}' | sort -n | head -1
            ;;
        stream)
            # Triad best rate, MB/s
            awk '/^Triad:/ {print $2}' "$file" 2>/dev/null | head -1
            ;;
        fio)
            # Highest aggregate bandwidth reported across the four passes
            grep -oE 'bw=[0-9.]+[KMG]?i?B/s' "$file" 2>/dev/null | sed 's/bw=//' | sort -h | tail -1
            ;;
    esac
}

metric_label() {
    case "$1" in
        hpl)                echo "gflops"      ;;
        allreduce|alltoall|allreduce-nonvlink|alltoall-nonvlink)
                            echo "busbw_GBs"   ;;
        nvbandwidth)        echo "min_GBs"     ;;
        stream)             echo "triad_MBs"   ;;
        fio)                echo "bw"          ;;
    esac
}

# ── Discover active jobs from launch_job.sh benchmarks variable ───────────────

declare -a job_order
declare -A job_total_runs

active_benchmarks=$(grep -E '^benchmarks=' "$home/actions/launch_job.sh" | head -1 | tr -d '"' | cut -d= -f2-)

for job in $active_benchmarks; do
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || continue
    if grep -Fq "totalRuns" "$sbatch"; then
        runs=$(grep -F totalRuns "$sbatch" | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        runs=1
    fi
    job_order+=("$job")
    job_total_runs["$job"]=$runs
done

# ── Discover nodes ────────────────────────────────────────────────────────────

nodes=$(ls -1 "$results_dir" 2>/dev/null | sort)
if [[ -z "$nodes" ]]; then
    echo "No results found in $results_dir"
    exit 0
fi

# ── Helper functions ──────────────────────────────────────────────────────────

## Status comes from verdict.sh, derived from the log on every report rather
## than read from a marker the sbatch wrote at run time. A result that passed an
## older, looser gate is re-judged here, so a report reflects what the current
## gate makes of the cluster rather than a mix of every gate ever deployed.
if [[ ! -f "$home/verdict.sh" ]]; then
    echo "ERROR: $home/verdict.sh is missing -- it carries the pass/fail rule for" >&2
    echo "       every job, and without it nothing can be judged." >&2
    exit 1
fi
source "$home/verdict.sh"

# ── Build the table ───────────────────────────────────────────────────────────
# Rows are assembled once, tab separated. The CSV on disk is the same rows with
# tabs swapped for commas, so the screen and the file can never disagree.

declare -a rows

header="node"
for job in "${job_order[@]}"; do
    runs=${job_total_runs[$job]}
    if [[ "$runs" -eq 1 ]]; then
        header+=$'\t'"${job}"
    else
        for ((r=1; r<=runs; r++)); do
            header+=$'\t'"${job}_run${r}"
        done
    fi
done
rows+=("$header")

for node in $nodes; do
    row="$node"
    for job in "${job_order[@]}"; do
        runs=${job_total_runs[$job]}
        mlabel=$(metric_label "$job")
        if [[ "$runs" -eq 1 ]]; then
            files=("$results_dir/$node/$job.txt")
        else
            files=()
            for ((r=1; r<=runs; r++)); do
                files+=("$results_dir/$node/$job-run${r}.txt")
            done
        fi
        for file in "${files[@]}"; do
            # Not $(...) -- a subshell would lose the reason. See verdict().
            verdict "$job" "$file"
            status="$VERDICT_STATUS"
            if [[ "$status" == "DONE" && -n "$mlabel" ]]; then
                metric=$(extract_metric "$job" "$file")
                row+=$'\t'"${metric:-$status}"
            else
                row+=$'\t'"${status}"
            fi
        done
    done
    rows+=("$row")
done

# ── Emit ──────────────────────────────────────────────────────────────────────

printf '%s\n' "${rows[@]}" | tr '\t' ',' > "$report_file"

if command -v column >/dev/null 2>&1; then
    printf '%s\n' "${rows[@]}" | column -t -s $'\t'
else
    printf '%s\n' "${rows[@]}"
fi

echo
echo "CSV written to: $report_file"

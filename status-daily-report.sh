#!/bin/bash
#
# Generates a dated CSV report of per-node benchmark status and performance metrics.
# Rows: nodes  |  Columns: per-job status + extracted metric (per run)
# Output: $home/reports/report-YYYY-MM-DD.csv

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
        allreduce|alltoall)
            # Find largest message size actually run, return out-of-place busbw
            awk '$1 ~ /^[0-9]+$/ {print}' "$file" 2>/dev/null | sort -k1,1n | tail -1 | awk '{print $8}'
            ;;
    esac
}

metric_label() {
    case "$1" in
        hpl)                echo "gflops"      ;;
        allreduce|alltoall) echo "busbw_GBs"   ;;
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

file_status() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "NOT_RUN"
        return
    fi
    local last
    last=$(tail -1 "$file")
    case "$last" in
        DONE) echo "DONE"        ;;
        FAIL) echo "FAIL"        ;;
        *)    echo "IN_PROGRESS" ;;
    esac
}

# ── Build CSV header ──────────────────────────────────────────────────────────

header="node"
for job in "${job_order[@]}"; do
    runs=${job_total_runs[$job]}
    if [[ "$runs" -eq 1 ]]; then
        header+=",${job}"
    else
        for ((r=1; r<=runs; r++)); do
            header+=",${job}_run${r}"
        done
    fi
done

echo "$header" > "$report_file"

# ── Build CSV rows ────────────────────────────────────────────────────────────

for node in $nodes; do
    row="$node"
    for job in "${job_order[@]}"; do
        runs=${job_total_runs[$job]}
        mlabel=$(metric_label "$job")
        if [[ "$runs" -eq 1 ]]; then
            file="$results_dir/$node/$job.txt"
            status=$(file_status "$file")
            if [[ "$status" == "DONE" && -n "$mlabel" ]]; then
                metric=$(extract_metric "$job" "$file")
                row+=",${metric:-$status}"
            else
                row+=",${status}"
            fi
        else
            for ((r=1; r<=runs; r++)); do
                file="$results_dir/$node/$job-run${r}.txt"
                status=$(file_status "$file")
                if [[ "$status" == "DONE" && -n "$mlabel" ]]; then
                    metric=$(extract_metric "$job" "$file")
                    row+=",${metric:-$status}"
                else
                    row+=",${status}"
                fi
            done
        fi
    done
    echo "$row" >> "$report_file"
done

echo "Report written to: $report_file"

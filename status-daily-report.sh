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

# Failed attempts archived by launch_job.sh as <job>.fail<N>.txt, summed across
# every run of the job. Reported in its own column so the result cells stay
# numeric for spreadsheet use.
fail_count() {
    local node="$1" job="$2"
    ls "$results_dir/$node" 2>/dev/null | grep -cE "^${job}(-run[0-9]+)?\.fail[0-9]+\.txt$"
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
    header+=",${job}_fails"
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
        row+=",$(fail_count "$node" "$job")"
    done
    echo "$row" >> "$report_file"
done

echo "Report written to: $report_file"

#!/bin/bash
#

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"
jobs_dir="$home/jobs"

# Read active benchmark list from launch_job.sh
active_benchmarks=$(grep -E '^benchmarks=' "$home/actions/launch_job.sh" | head -1 | tr -d '"' | cut -d= -f2-)

# Build ordered job+run list matching what launch_job.sh actually tracks
declare -a columns  # each entry is "job" or "job-runN"

for job in $active_benchmarks; do
    sbatch="$jobs_dir/$job.sbatch"
    [[ -f "$sbatch" ]] || continue
    if grep -Fq "totalRuns" "$sbatch"; then
        totalRuns=$(grep -F totalRuns "$sbatch" | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        totalRuns=1
    fi

    if [[ "$totalRuns" -eq 1 ]]; then
        columns+=("$job")
    else
        for ((r=1; r<=totalRuns; r++)); do
            columns+=("${job}-run${r}")
        done
    fi
done

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

# Emit one line per node per column, then pipe to dshbak for grouping
for node_dir in "$results_dir"/*/; do
    node=$(basename "$node_dir")
    for col in "${columns[@]}"; do
        file="$results_dir/$node/${col}.txt"
        status=$(file_status "$file")
        echo "$node: $col: $status"
    done
done | sort | dshbak -c

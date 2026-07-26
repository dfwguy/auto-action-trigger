#!/bin/bash
#
# Usage: status-check.sh [pattern]
#
#   pattern  optional node-name filter. A bare string matches every node whose
#            name starts with it, so a rack prefix (dh01-rack01) covers the
#            whole rack. Shell globs (dh01-rack0[12]*, *node05) are honored as
#            written, so an explicit pattern can match anywhere in the name.
#            With no pattern, every node under results/ is reported.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"
jobs_dir="$home/jobs"

pattern="$1"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

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

matched=0
for node_dir in "$results_dir"/$pattern/; do
    [[ -d "$node_dir" ]] && matched=1 && break
done
if [[ "$matched" -eq 0 ]]; then
    echo "No nodes under $results_dir match '${1:-*}'" >&2
    exit 1
fi

# Emit one line per node per column, then pipe to dshbak for grouping
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
        # A passing column is done -- how many tries it took is history, not
        # status, and annotating it splits DONE nodes into dshbak groups that
        # all mean the same thing. The archives stay on disk either way, and
        # the daily CSV still carries the per-job counts.
        [[ "$status" == "DONE" ]] && fails=0
        # The reason is part of the line on purpose. dshbak groups identical
        # lines, so nodes failing the same way collapse into one block and a
        # single node failing differently stands out -- the same reason
        # health-check.sh groups by failure signature rather than by check.
        line="$node: $col: $status"
        [[ "$status" != "DONE" && "$status" != "NOT_RUN" && -n "$reason" ]] && line+=" -- $reason"
        [[ "$fails" -gt 0 ]] && line+=" (fails: $fails)"
        echo "$line"
    done
done | sort | dshbak -c

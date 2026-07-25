#!/bin/bash
#
#

#[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

## Active single-node benchmark list. Everything without a passing result is
## queued once an hour, in the order listed here.
##
## Available single-node jobs in jobs/ (AI Factory Testing Plan, SNT tiers):
##   dcgm-r2                TTM DCGM gate      (dcgmi diag -r 2)
##   dcgm                   Hybrid DCGM gate   (dcgmi diag -r 3)
##   dcgm-r4                Exhaustive gate    (dcgmi diag -r 4)
##   nvbandwidth            HBM / PCIe / NVLink bandwidth
##   allreduce alltoall     NCCL single node, NVLink scope
##   allreduce-nonvlink     NCCL single node, no NVLink (HCA loopback)
##   alltoall-nonvlink      NCCL single node, no NVLink (HCA loopback)
##   nvsm                   NVSM stress (Hybrid / Exhaustive only)
##   stream memtester       CPU memory bandwidth + DRAM integrity (Exhaustive)
##   stress-ng              CPU stress (Exhaustive)
##   stressapptest          extended memory integrity (Exhaustive)
##   fio                    local NVMe / shared storage (Exhaustive)
##   ethr                   north-south management + storage NIC (Exhaustive)
##   nvloom                 MNNVL fabric (Exhaustive, optional/exploratory)
##   mnubergemm             burn-in (Hybrid / Exhaustive)
##   llm-pretrain           single-node LLM pre-training workload gate
##   hpl cublasmatmul       remediation-only single-node GEMM -- run by hand
##
## Pick the set matching the delivery methodology for the site.
## Default list holds only jobs that need nothing built or installed on our
## side: dcgm and nvsm use host binaries, the NCCL jobs pull the public
## nvcr.io#nvidia/hpc-benchmarks image. Jobs needing a container we have to
## build or import (nvbandwidth, nvloom, mnubergemm) are covered in
## MAKE_CONTAINERS.md and are added here once their image exists.
##
## nvsm sits between the NVLink NCCL jobs and the no-NVLink ones so that a
## fabric problem does not push a GPU stress test to the back of the queue --
## nvsm has no fabric dependency and should report early.
benchmarks="dcgm allreduce alltoall nvsm allreduce-nonvlink alltoall-nonvlink"
MAX_JOB_HOURS=6

## Retry policy.
##
## Once an hour, every benchmark in the list above that does not have a passing
## result is queued, in listed order. Slurm runs them back to back on the node.
## There is no retry limit -- a node keeps being re-tested until it passes or an
## operator intervenes.
##
## This script fires on every BCM monitoring cycle, so the hourly cadence needs
## no cron and no second trigger -- just a time gate. Retry state is derived
## entirely from files already on disk: the newest result file's mtime is when
## the last sweep ran, and prior failures are archived as <job>.fail<N>.txt.
## There is no state file to keep in sync.
##
## The node is drained only once a full sweep has been attempted -- every
## benchmark has run at least once and something is still not passing. A single
## failure mid-sweep does not drain, so the rest of the sweep still runs and one
## bad test does not hide the state of the others.
##
## The drain reason carries a marker, and only drains carrying that marker are
## ever cleared. An operator drain is never auto-resumed, and a node already
## drained for another reason is left alone.
RETRY_INTERVAL_HOURS=1
DRAIN_MARKER="auto-retry"

source /etc/profile.d/modules.sh
module load slurm

## set paths
home=/home/cmods/bringup
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"

## Result file for run $2 of job $1. Single-run jobs use <job>.txt.
result_file() {
    local job="$1" run="$2" total="$3"
    if [[ "$total" -eq 1 ]]; then
        echo "$logs/$job.txt"
    else
        echo "$logs/$job-run${run}.txt"
    fi
}

## Move a non-passing result aside as <name>.fail<N>.txt so the slot is free
## for the next attempt. The archives double as the per-job attempt history.
archive_result() {
    local file="$1" base n
    [[ -f "$file" ]] || return 0
    base=$(basename "$file" .txt)
    n=$(ls "$logs" 2>/dev/null | grep -cE "^${base}\.fail[0-9]+\.txt$")
    mv "$file" "$logs/${base}.fail$((n + 1)).txt"
}

## Drain only if the node is currently usable and not already drained by us.
## A node drained for any other reason is left alone.
##
## `touch /home/cmods/bringup/NODRAIN` disables every drain this script would
## issue, including the MAX_JOB_HOURS timeout drain. Testing continues exactly
## as before — results are still recorded and failures still retry hourly — the
## node is just never taken out of service. Remove the file to re-enable.
drain_node() {
    local reason="$1"
    [[ -f "$home/NODRAIN" ]] && return 0
    case "$state" in
        *drain*|*down*|*fail*|*maint*) return 0 ;;
    esac
    scontrol update nodename="$HOSTNAME" state=DRAIN reason="$reason"
}

## Clear only our own drain — the marker is what makes this safe.
resume_node() {
    local current
    current=$(sinfo -n "$HOSTNAME" -h -o '%E' 2>/dev/null | head -1)
    [[ "$current" == *"$DRAIN_MARKER"* ]] || return 0
    scontrol update nodename="$HOSTNAME" state=RESUME
}

## Check if node is in slurm; if not - quit
state=$(sinfo -N -n "$HOSTNAME" -h -o '%T')
[[ -z "$state" ]] && exit 0

## If a job is actively running or pending on this node, wait.
## Check elapsed time against MAX_JOB_HOURS and drain if stuck.
job_info=$(squeue -h -w "$HOSTNAME" -o '%M %T' 2>/dev/null | head -1)
if [[ -n "$job_info" ]]; then
    elapsed="${job_info%% *}"
    job_state="${job_info##* }"

    # Parse elapsed time — squeue formats: MM:SS, HH:MM:SS, D-HH:MM:SS
    elapsed_hours=0
    if [[ "$elapsed" =~ ^([0-9]+)-([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        elapsed_hours=$(( ${BASH_REMATCH[1]} * 24 + ${BASH_REMATCH[2]} ))
    elif [[ "$elapsed" =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        elapsed_hours=${BASH_REMATCH[1]}
    fi

    if [[ "$elapsed_hours" -ge "$MAX_JOB_HOURS" ]]; then
        drain_node "benchmark timeout after ${elapsed_hours}h (${job_state})"
    fi
    exit 0
fi

mkdir -p "$logs"

## ── Survey what has and has not passed ────────────────────────────────────
## A job passes when every one of its runs ends in DONE. Anything else — FAIL,
## truncated output from a crashed node, or no file at all — is not a pass and
## gets queued again on the next sweep.

declare -a pending_jobs=()
declare -a failed_jobs=()
declare -A job_runs=()
newest_result=0
swept=1

for job in $benchmarks; do
    launch="$home/jobs/$job.sbatch"
    [[ -f "$launch" ]] || continue

    if grep -Fq "totalRuns" "$launch"; then
        totalRuns=$(grep -F totalRuns "$launch" | head -1 | awk -F= '{print $2}' | tr -d '[:space:]')
    else
        totalRuns=1
    fi
    [[ "$totalRuns" =~ ^[0-9]+$ ]] && [[ "$totalRuns" -gt 0 ]] || totalRuns=1
    job_runs["$job"]=$totalRuns

    passed=0
    attempted=0
    failed=0
    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        [[ -f "$file" ]] || continue
        attempted=1

        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        [[ "$mtime" -gt "$newest_result" ]] && newest_result=$mtime

        case "$(tail -1 "$file" 2>/dev/null)" in
            DONE) passed=$((passed + 1)) ;;
            FAIL) failed=1 ;;
        esac
    done

    ## Archived attempts still count as having run — a job whose output was
    ## rotated aside is mid-retry, not untested.
    if [[ "$attempted" -eq 0 ]] &&
       ls "$logs" 2>/dev/null | grep -qE "^${job}(-run[0-9]+)?\.fail[0-9]+\.txt$"; then
        attempted=1
    fi

    [[ "$attempted" -eq 0 ]] && swept=0
    [[ "$failed" -eq 1 ]] && failed_jobs+=("$job")
    [[ "$passed" -lt "$totalRuns" ]] && pending_jobs+=("$job")
done

## ── Everything passing — nothing left to do ───────────────────────────────

if [[ "${#pending_jobs[@]}" -eq 0 ]]; then
    printf '%s: DONE\n' $benchmarks > "$quickview"
    resume_node
    exit 0
fi

## ── Drain once the full sweep has run and something is still failing ──────
## Not on the first failure — the rest of the sweep still needs to run, and one
## bad test should not hide the state of the others.

if [[ "$swept" -eq 1 && "${#failed_jobs[@]}" -gt 0 ]]; then
    drain_node "${failed_jobs[*]} FAIL ($DRAIN_MARKER)"
fi

## ── Hourly gate ───────────────────────────────────────────────────────────

if [[ "$newest_result" -gt 0 ]]; then
    age=$(( $(date +%s) - newest_result ))
    [[ "$age" -lt $(( RETRY_INTERVAL_HOURS * 3600 )) ]] && exit 0
fi

## ── Queue every non-passing job, in listed order ──────────────────────────

## A node drained by an operator stays untouched — queueing work behind their
## drain would dump the whole batch on the node the moment they resume it.
drain_reason=$(sinfo -n "$HOSTNAME" -h -o '%E' 2>/dev/null | head -1)
case "$state" in
    *drain*|*down*|*fail*|*maint*)
        [[ "$drain_reason" == *"$DRAIN_MARKER"* ]] || exit 0
        ;;
esac

resume_node

for job in "${pending_jobs[@]}"; do
    launch="$home/jobs/$job.sbatch"
    totalRuns=${job_runs["$job"]}

    for ((r = 1; r <= totalRuns; r++)); do
        file=$(result_file "$job" "$r" "$totalRuns")
        [[ -f "$file" && "$(tail -1 "$file" 2>/dev/null)" == "DONE" ]] && continue
        archive_result "$file"

        su - cmods -c "source /etc/profile.d/modules.sh; module load slurm; \
            mkdir -p $logs && sbatch -w $HOSTNAME --export=ALL,RESULT_FILE=$file --output=$file $launch"
    done
done

## Reflect the newly queued state for anyone reading quick-view directly
{
    for job in $benchmarks; do
        if printf '%s\n' "${pending_jobs[@]}" | grep -Fxq "$job"; then
            echo "$job: QUEUED"
        else
            echo "$job: DONE"
        fi
    done
} > "$quickview"

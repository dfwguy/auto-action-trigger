#!/bin/bash
#
#

#[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

## Active single-node benchmark sequence. Jobs run in order; each must finish
## DONE before the next starts.
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
benchmarks="dcgm allreduce alltoall"
MAX_JOB_HOURS=6

source /etc/profile.d/modules.sh
module load slurm

## set paths
home=/home/cmods/bringup
logs="$home/results/$HOSTNAME"
quickview="$logs/quick-view.txt"

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
        scontrol update nodename="$HOSTNAME" state=DRAIN \
            reason="benchmark timeout after ${elapsed_hours}h (${job_state})"
    fi
    exit 0
fi

for job in $benchmarks; do
    launch="$home/jobs/$job.sbatch"

    if grep -Fq "totalRuns" "$launch"; then
        totalRuns=$(grep -F totalRuns "$launch" | awk -F= '{print $2}')
    else
        totalRuns=1
    fi

    if [[ $totalRuns -eq 1 ]]; then
        completedRuns=$([[ -f "$logs/$job.txt" ]] && echo 1 || echo 0)
        lastFile="$logs/$job.txt"
        nextFile="$logs/$job.txt"
        nextRun=1
    else
        completedRuns=$(ls "$logs" 2>/dev/null | grep -cE "^${job}-run[0-9]+\.txt$")
        nextRun=$((completedRuns + 1))
        lastFile="$logs/$job-run${completedRuns}.txt"
        nextFile="$logs/$job-run${nextRun}.txt"
    fi

    if [[ -f "$lastFile" ]]; then
        checks=$(tail -1 "$lastFile")
    else
        checks="empty"
    fi

    ## Benchmark failed — log it, drain the node, and stop processing
    if [[ "$checks" == "FAIL" ]]; then
        if ! grep -Fq "$job:" "$quickview" 2>/dev/null; then
            echo "$job: FAIL" >> "$quickview"
        fi
        scontrol update nodename="$HOSTNAME" state=DRAIN reason="$job FAIL"
        exit 0
    fi

    ## All runs finished — log it and move to next benchmark
    if [[ "$checks" == "DONE" && "$completedRuns" -ge "$totalRuns" ]]; then
        if ! grep -Fq "$job:" "$quickview" 2>/dev/null; then
            echo "$job: DONE" >> "$quickview"
        fi
        continue
    fi

    ## Submit the next run if node is idle
    if [[ "$state" == "idle" && "$nextRun" -le "$totalRuns" ]]; then
        su - cmods -c "source /etc/profile.d/modules.sh; module load slurm; \
            mkdir -p $logs && sbatch -w $HOSTNAME --export=ALL,RESULT_FILE=$nextFile --output=$nextFile $launch"
        exit 0
    fi
done

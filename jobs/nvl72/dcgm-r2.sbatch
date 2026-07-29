#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH -t 0:25:00
## Steps inherit only what was explicitly requested. See
## docs/benchmarks.md#the-allocation-header.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
## Higher is LATER; the dcgm gates lead the sweep. See
## docs/benchmarks.md#queue-priority.
#SBATCH --nice=0
##SBATCH -o /home/cmods/bringup/results/%N/dcgm-r2.txt

## Time to Market gate. See docs/settings.md#available-single-node-jobs-jobsnvl72.

## Job name is used in the status line.
# shellcheck disable=SC2034  # read by the status line, not by this script
job_name=dcgm-r2

## 2x ~2 min, floored at 15 min; `timeout` because dcgmi is not a step, and
## #SBATCH -t above carries the margin. See
## docs/benchmarks.md#two-time-limits-and-the-order-they-fire-in.
JOB_TIMEOUT=15m

## ------------- job info starts here ------------- ##

## What the STEP holds, which only a step can see. Wording is fixed -- the
## parse block and verdict.sh grep this file. See docs/benchmarks.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
##
## TERM first so dcgmi tears down its host engine connection, KILL 60s later
## for one that will not go -- hence 124 *or* 137 below.
timeout --signal=TERM --kill-after=60 "$JOB_TIMEOUT" dcgmi diag -r 2
rc=$?

## Fixed wording VERDICT_RUN_ERRORS matches; an overrun must say so rather
## than look like a dead node.
[[ "$rc" -eq 124 || "$rc" -eq 137 ]] && echo "timeout: killed after ${JOB_TIMEOUT}"


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here; verdict.sh judges the result. See
## docs/benchmarks.md#where-a-pass-is-decided.

## Says who decided a FAIL: non-zero is the workload's, 0 is verdict.sh's gate.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

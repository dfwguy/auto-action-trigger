#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH -t 0:50:00
## Not implied by --exclusive: a step inherits only what was named.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH --nice=0
## 0 is the front of the queue -- the dcgm gates decide whether the rest of the
## sweep is worth running. See docs/benchmarks.md#queue-priority.
##SBATCH -o /home/cmods/bringup/results/%N/dcgm.txt

## No --cpus-per-task anywhere: it implies --exact and shrinks the step. See
## docs/benchmarks.md#the-allocation-header.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=dcgm

## 2x ~20 min, the plan's estimate for dcgmi -r 3. `timeout` rather than
## `srun --time` because dcgmi runs in the batch script body, not a step. See
## docs/benchmarks.md#two-time-limits-and-the-order-they-fire-in.
JOB_TIMEOUT=40m

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP holds; only a step can see that. Wording is fixed,
## verdict.sh greps this file. See docs/benchmarks.md#preflight.
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
## TERM first so dcgmi can tear down its host engine connection; KILL 60s later
## for one that will not go, which is why both 124 and 137 count below.
timeout --signal=TERM --kill-after=60 "$JOB_TIMEOUT" dcgmi diag -r 3
rc=$?

## Fixed wording VERDICT_RUN_ERRORS matches, so an overrun reads as one rather
## than as a node that mysteriously stopped.
[[ "$rc" -eq 124 || "$rc" -eq 137 ]] && echo "timeout: killed after ${JOB_TIMEOUT}"


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here; whether it was any good is
## verdict.sh's call. See docs/benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero here is the job's own; with `exit status: 0` it came
## from verdict.sh, which leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH -t 0:25:00
## Steps inherit only what was named here, never what --exclusive implied.
## See docs/reference/jobs.md#the-allocation-header.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH --nice=1
## Matches the -r level, so the gates run in order; ahead of the sweep they gate,
## behind a hand-submitted job, which defaults to 0. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/dcgmi-r1.txt

## DCGM diagnostics at run level 1. The four dcgmi-r* jobs differ only in the
## -r level and the time that level needs. See docs/reference/jobs.md#the-dcgmi-gates.

## Job name is used in the status line.
# shellcheck disable=SC2034  # consumed by the status line, not by this script
job_name=dcgmi-r1

## `timeout` rather than srun --time because dcgmi runs in the batch body, not
## a step; the derivation is in
## docs/reference/jobs.md#what-each-jobs-limits-were-derived-from. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
JOB_TIMEOUT=15m

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which the job's AllocTRES cannot answer.
## The wording is fixed; verdict.sh greps this file. See
## docs/reference/jobs.md#preflight and example.sbatch.
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
## TERM first so dcgmi tears down its host engine connection; KILL 60s later
## for one that will not go, which is why 137 counts alongside 124 below.
timeout --signal=TERM --kill-after=60 "$JOB_TIMEOUT" dcgmi diag -r 1
rc=$?

## Fixed wording VERDICT_RUN_ERRORS matches, so an overrun does not read as a
## dead node. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
[[ "$rc" -eq 124 || "$rc" -eq 137 ]] && echo "timeout: killed after ${JOB_TIMEOUT}"


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here; whether it passed is verdict.sh's
## call, made at status-check time. See
## docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## Says who decided a FAIL: non-zero is the workload's own, 0 is verdict.sh.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

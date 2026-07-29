#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:10:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/benchmarks.md#queue-priority.
##SBATCH -o /home/cmods/bringup/results/%N/llm-pretrain.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/benchmarks.md#the-allocation-header.
##
## Recipe is still TBD: LLMB_SCALE below is 8 while this asks for 4 GPUs, and
## the two have to agree before this job is enabled. Set both from the GPU
## count of the platform under test.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=llm-pretrain

## Handed to srun --time below; #SBATCH -t is this plus a margin so the step
## limit fires first. See docs/benchmarks.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=2:00:00

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP holds, which the job's AllocTRES cannot answer.
## The passing line's wording is fixed. See docs/benchmarks.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## llmb-run installation root (llmb_install from the LLMB installer)
export LLMB_INSTALL=/home/cmods/bringup/llmb
export LLMB_WORKLOAD=pretrain_nemotron-h
export LLMB_MODEL_SIZE=56b
export LLMB_DTYPE=fp8
export LLMB_SCALE=8          # GPUs on the single node under test

## Site-specific Slurm/container settings consumed by llmb-run
export SBATCH_PARTITION="${SLURM_JOB_PARTITION}"
#export SBATCH_ACCOUNT=
#export HF_TOKEN=

cd "${LLMB_INSTALL}" || exit 1

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 --export=ALL \
    llmb-run single \
        -w "${LLMB_WORKLOAD}" \
        -s "${LLMB_MODEL_SIZE}" \
        --dtype "${LLMB_DTYPE}" \
        --scale "${LLMB_SCALE}"
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. See docs/benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero status here is srun's own; a FAIL with `exit
## status: 0` came from the gate in verdict.sh, which leaves no trace here.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

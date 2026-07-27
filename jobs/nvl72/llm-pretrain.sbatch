#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:10:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/llm-pretrain.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them. Without the --gres line this job held
## an exclusive node and handed its srun zero GPUs. --cpus-per-task is
## deliberately absent: it implies --exact and would shrink the step.
## See docs/benchmarks.md.
##
## LLMB_SCALE below is 8 while this asks for 4 GPUs -- the recipe is still TBD
## and the two have to agree before this job is enabled. Set both from the GPU
## count of the platform under test.

## AI Factory Testing Plan: Single-Node LLM Pre-Training -- SNT3
## End-to-end pre-training scoped to one node. Validates the full workload
## stack: framework, containers, data pipeline, checkpointing, and intra-node
## collectives. Primary workload gate in TTM Single Node; node-level workload
## check in Hybrid before multi-node NCCL.
##
## Recipe is still TBD -- see incubation/TTM_Single_Node_Workload_MOP.md in the
## validation-mops repo. FastTrack variant uses pretrain_nemotron-h at minimum
## supported scale via llmb-run; candidates are Llama 3.1 8B (Megatron-Bridge,
## 8 GPUs, FP8/NVFP4) with Qwen3 30B (BF16) as the ungated fallback.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=llm-pretrain

## Step time limit, handed to srun --time below: 2x the plan's ~30-60 min,
## taking the upper end.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=2:00:00

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
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

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

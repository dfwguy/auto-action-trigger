#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 1:10:00
#SBATCH --nice=20
## --nice 20 is the sweep's tier; higher is LATER. See
## docs/benchmarks.md#queue-priority.
##SBATCH -o /home/cmods/bringup/results/%N/llm-pretrain-solo.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/benchmarks.md#the-allocation-header.

## Four INDEPENDENT copies of a single-GPU pre-training run, one per GPU, so the
## four step times can be compared against each other and a slow GPU names
## itself. The sibling job llm-pretrain runs the SAME recipe 4-way data
## parallel and exercises the gradient all-reduce; this one deliberately has no
## collectives in it at all. See docs/llmb.md#the-two-llm-jobs.
##
## Not launched through llmb-run: four scale-1 submissions would be four Slurm
## jobs, and they cannot co-schedule on an --exclusive node. The training
## command comes out of `llmb-run submit ... --scale 1 --dry-run` instead.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=llm-pretrain-solo
# shellcheck disable=SC2034
totalRuns=1

## Handed to srun --time below; #SBATCH -t is this plus a margin so the step
## limit fires first. See docs/benchmarks.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=1:00:00

## ------------- job info starts here ------------- ##

## What the STEP holds, which only a step can answer. Wording is fixed: the
## parse block and verdict.sh grep it. See docs/benchmarks.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Staged into containers/ by build_llmb.sh, then rsynced node-local by
## file_copy.sh like every other image. Node-local first, NFS as fallback: four
## ranks opening a multi-GB squashfs over NFS at once is the case this avoids.
## See docs/llmb.md#getting-the-image-to-the-nodes.
IMG=$(cd /tmp/containers 2>/dev/null && ls llama3.1*.sqsh 2>/dev/null | head -1)
CONT=/tmp/containers/$IMG
if [[ -z "$IMG" || ! -f "$CONT" ]]; then
    IMG=$(cd /home/cmods/bringup/containers 2>/dev/null && ls llama3.1*.sqsh 2>/dev/null | head -1)
    CONT=/home/cmods/bringup/containers/$IMG
fi
## Named rather than globbed-and-hoped: an empty glob would otherwise reach srun
## as --container-image= and fail as something else entirely.
[[ -n "$IMG" && -f "$CONT" ]] || {
    echo "no llama3.1 image in /tmp/containers or /home/cmods/bringup/containers"
    echo "run ./build_llmb.sh on the head node -- see docs/llmb.md"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## The same recipe its sibling runs, at scale 1 instead of 4. Llama 3.1 8B on
## GB200 is pure data parallel -- TP=1, PP=1, CP=1, FSDP=False, DP=GPUs -- so
## every rank already holds a whole replica and one GPU is a valid
## configuration, even though it is below the recipe's characterised floor of 8.
## See docs/llmb.md#running-below-the-characterised-scale.
LLMB_INSTALL=${LLMB_INSTALL:-/home/cmods/llmb}
WORKLOAD=pretrain_llama3.1
MODEL_SIZE=8b
DTYPE=fp8

## Read offline; the compute nodes have no route out. An absent cache entry is a
## failed run rather than a slow one, which is what these three make it.
## See docs/llmb.md#running-offline.
export HF_HOME="$LLMB_INSTALL/hf"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

## ── The four independent ranks ────────────────────────────────────────────
##
## --gpus-per-task=1 is what makes them independent: Slurm hands each task its
## own CUDA_VISIBLE_DEVICES, so rank N trains on GPU N and sees no other.
##
## WORLD_SIZE=1 is load-bearing and not redundant. NeMo reads the SLURM_* rank
## variables and would form ONE four-way distributed group across these tasks --
## which is the sibling job, not this one, and would report a single step time
## instead of four. See docs/llmb.md#keeping-the-four-copies-independent.
##
## --label prefixes every line with its task id. That prefix is the only thing
## tying a step time to a GPU, and verdict.sh parses it.
unset CUDA_VISIBLE_DEVICES

srun --time="$STEP_TIMELIMIT" --label --export=ALL \
        --ntasks=4 --gpus-per-task=1 \
        --cpu-bind=cores \
        --container-image="${CONT}" \
        --container-mounts="${LLMB_INSTALL}:${LLMB_INSTALL}:ro" \
        bash -c '
    export WORLD_SIZE=1 RANK=0 LOCAL_RANK=0
    export CUDA_DEVICE_MAX_CONNECTIONS=1
    echo "gpu $SLURM_PROCID: $(nvidia-smi --query-gpu=uuid --format=csv,noheader)"
    ## ---------------------------------------------------------------------
    ## TRAINING COMMAND -- fill this in from
    ##   llmb-run submit -w '"$WORKLOAD"' -s '"$MODEL_SIZE"' --dtype '"$DTYPE"' \
    ##                   --scale 1 --force --dry-run
    ## run on the head node. Take the training invocation out of the generated
    ## script, not the sbatch wrapper around it. It must be a SINGLE-PROCESS
    ## invocation: no torchrun, no srun, no distributed launcher. See
    ## docs/llmb.md#filling-in-the-solo-training-command.
    ## ---------------------------------------------------------------------
    echo "llm-pretrain-solo: no training command configured -- see docs/llmb.md#filling-in-the-solo-training-command" >&2
    exit 1
'
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the four GPUs agree is
## verdict.sh's call, re-read on every status check.
## See docs/benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero status here is srun's own; a FAIL with `exit
## status: 0` came from the gate in verdict.sh, which leaves no trace here.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

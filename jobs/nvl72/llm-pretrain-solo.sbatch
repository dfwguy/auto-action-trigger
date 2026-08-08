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
## docs/reference/jobs.md#queue-priority.
##SBATCH -o <BRINGUP_HOME>/results/%N/llm-pretrain-solo.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## Four INDEPENDENT copies of a single-GPU run, one per GPU, so a slow GPU names
## itself. No collectives at all -- the sibling job llm-pretrain covers those.
## Not launched through llmb-run: four scale-1 submissions would be four Slurm
## jobs and cannot co-schedule on an --exclusive node.
## See docs/explanation/llmb.md.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=llm-pretrain-solo
# shellcheck disable=SC2034
totalRuns=1

## Handed to srun --time below; #SBATCH -t is this plus a margin so the step
## limit fires first. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=1:00:00

## ------------- job info starts here ------------- ##

## What the STEP holds, which only a step can answer. Wording is fixed: the
## parse block and verdict.sh grep it. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Node-local copy first, NFS as fallback. See docs/explanation/containers.md#why-local-images.
IMG=$(cd /tmp/containers 2>/dev/null && ls llama3.1*.sqsh 2>/dev/null | head -1)
CONT=/tmp/containers/$IMG
if [[ -z "$IMG" || ! -f "$CONT" ]]; then
    shared=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}
    IMG=$(cd "$shared" 2>/dev/null && ls llama3.1*.sqsh 2>/dev/null | head -1)
    CONT=$shared/$IMG
fi
## An empty glob would reach srun as --container-image= and fail as something else.
[[ -n "$IMG" && -f "$CONT" ]] || {
    echo "no llama3.1 image in /tmp/containers or $shared"
    echo "run ./build_llmb.sh on the head node -- see docs/explanation/llmb.md"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## The sibling's recipe at scale 1. Why one GPU is a valid configuration:
## docs/explanation/llmb.md#running-below-the-characterised-scale.
LLMB_INSTALL=${LLMB_INSTALL:?not set -- launch_job.sh exports it; a bare sbatch must too}
WORKLOAD=pretrain_llama3.1
MODEL_SIZE=8b
DTYPE=fp8

## A cache miss on a node with no route out must fail, not stall.
## See docs/explanation/llmb.md#running-offline.
export HF_HOME="${LLMB_HF:-$LLMB_INSTALL/hf}"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

## ── The four independent ranks ────────────────────────────────────────────
## Three things are load-bearing here and all three are explained in
## docs/explanation/llmb.md#keeping-the-four-solo-copies-independent: --gpus-per-task=1 (one GPU
## per rank), WORLD_SIZE=1 (stops NeMo forming one four-way group across them),
## and --label (the task-id prefix verdict.sh parses).
unset CUDA_VISIBLE_DEVICES

## An adopted install can keep its HF cache outside the install root, and a
## mount that does not cover HF_HOME is an offline cache miss inside the
## container. See docs/explanation/llmb.md#adopting-an-existing-install.
MOUNTS="${LLMB_INSTALL}:${LLMB_INSTALL}:ro"
case "$HF_HOME" in
    "$LLMB_INSTALL"/*) ;;
    *) MOUNTS="${MOUNTS},${HF_HOME}:${HF_HOME}:ro" ;;
esac

srun --time="$STEP_TIMELIMIT" --label --export=ALL \
        --ntasks=4 --gpus-per-task=1 \
        --cpu-bind=cores \
        --container-image="${CONT}" \
        --container-mounts="${MOUNTS}" \
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
    ## docs/how-to/enable-llm-pretrain.md#3-filling-in-the-solo-training-command.
    ## ---------------------------------------------------------------------
    echo "llm-pretrain-solo: no training command configured -- see docs/how-to/enable-llm-pretrain.md#3-filling-in-the-solo-training-command" >&2
    exit 1
'
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the four GPUs agree is
## verdict.sh's call. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
##
## A FAIL with a non-zero status here is srun's own; `exit status: 0` with FAIL
## came from the gate, which leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

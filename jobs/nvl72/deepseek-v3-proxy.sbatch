#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH --segment=1
#SBATCH -t 0:50:00
#SBATCH --nice=20
## --nice 20 is the sweep's tier; higher is LATER. See
## docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/deepseek-v3-proxy.txt

## DeepSeek-V3 reduced proxy from Exemplar v26.06.01: four GB300 GPUs,
## FP8-MX, TP=1, PP=1, VP disabled, EP=4, 24 layers, hidden size 1024,
## micro-batch 4. This uses synthetic data, not full 671B model weights.
## Keep the payload paired with the NeMo 26.04.01 image. See
## docs/how-to/run-deepseek-v3-proxy.md before changing either version.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=deepseek-v3-proxy
# shellcheck disable=SC2034
totalRuns=1

## Handed to srun --time below; #SBATCH -t is this plus a margin so the step
## limit fires first. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:40:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

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

## Match the pinned ARM image exactly, excluding NCCL-modified variants.
nemo_image() {
    local f="$1/nvidia+nemo+26.04.01-arm.sqsh"
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
    return 1
}
[[ "$(uname -m)" == aarch64 ]] || {
    echo "DeepSeek proxy requires a four-GPU GB300 ARM node"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## Node-local copy first, NFS as fallback. See docs/explanation/containers.md#why-local-images.
shared=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}
CONT=$(nemo_image "${NODE_CONTAINER_DIR:-/opt/containers}")
[[ -n "$CONT" ]] || CONT=$(nemo_image "$shared")

## An empty glob would reach srun as --container-image= and fail as something else.
[[ -n "$CONT" && -f "$CONT" ]] || {
    echo "no pinned nvidia+nemo+26.04.01-arm image for $(uname -m) in ${NODE_CONTAINER_DIR:-/opt/containers} or $shared"
    echo "build it with the right -a, or copy it out of the llmb install --"
    echo "see docs/how-to/build-containers.md#nemo"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## A cache miss on a node with no route out must fail, not stall.
## See docs/explanation/llmb.md#running-offline.
LLM_HF_HOME=${LLM_HF_HOME:-}
[[ "$LLM_HF_HOME" == /* && "$LLM_HF_HOME" != *:* && "$LLM_HF_HOME" != *,* ]] || {
    echo "LLM_HF_HOME must be an absolute mount path without ':' or ',': ${LLM_HF_HOME:-<unset>}"
    echo "exit status: 1"
    echo FAIL
    exit 0
}
[[ -d "$LLM_HF_HOME" && -n "$(find "$LLM_HF_HOME" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
    echo "LLM_HF_HOME is missing or empty: $LLM_HF_HOME"
    echo "the node cannot download missing recipe assets -- see docs/how-to/run-deepseek-v3-proxy.md"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## Existing LLM runtime environment; validate against the pinned DeepSeek payload.
## See docs/how-to/run-deepseek-v3-proxy.md.
export CUDA_DEVICE_MAX_CONNECTIONS=32
export NCCL_NVLS_ENABLE=0
export NVTE_FWD_LAYERNORM_SM_MARGIN=16
export NVTE_BWD_LAYERNORM_SM_MARGIN=16
export TOKENIZERS_PARALLELISM=False
export TORCH_NCCL_AVOID_RECORD_STREAMS=1
export TORCH_NCCL_HIGH_PRIORITY=1
export PYTHONUNBUFFERED=1

MOUNTS="${LLM_HF_HOME}:/hf-cache"
echo "recipe: Exemplar=v26.06.01 NeMo=26.04.01 DeepSeek-V3 proxy FP8-MX TP=1 PP=1 VP=None EP=4 layers=24 hidden=1024 micro_batch=4 steps=50"
echo "execution: job=${SLURM_JOB_ID:-unknown} node=$(hostname) image=$CONT"

## numactl pins each of the four local ranks to the NUMA node its GPU sits on --
## a GB200/GB300 tray assumption, and the first line to revisit on other
## hardware. See docs/explanation/llmb.md#the-numa-binding.
srun --time="$STEP_TIMELIMIT" --label --export=ALL \
        --ntasks=4 \
        --wait=60 --kill-on-bad-exit=1 \
        --mpi=pmix \
        --container-image="${CONT}" \
        --container-mounts="${MOUNTS}" \
        --container-workdir=/tmp \
        --no-container-mount-home --container-writable \
        bash -c '
    PERF_SCRIPT=/opt/Megatron-Bridge/scripts/performance/run_script.py
    [[ -f "$PERF_SCRIPT" ]] || {
        echo "no $PERF_SCRIPT in the nvidia+nemo image"
        exit 1
    }
    export HF_HOME=/hf-cache
    export HF_HUB_OFFLINE=1 HF_DATASETS_OFFLINE=1 TRANSFORMERS_OFFLINE=1
    export NEMORUN_HOME=/mnt/nemo
    mkdir -p "$NEMORUN_HOME/experiments"
    numactl --cpunodebind=$((SLURM_LOCALID/2)) --membind=$((SLURM_LOCALID/2)) \
    python "$PERF_SCRIPT" \
        --model_family_name deepseek \
        --model_recipe_name deepseek_v3 \
        --gpu gb300 \
        --container_image '"$CONT"' \
        --num_gpus 4 \
        --gpus_per_node 4 \
        --offline \
        --max_steps=50 \
        --custom_mounts=/hf-cache \
        --compute_dtype fp8_mx \
        --enable_pct_binding false \
        -tp 1 \
        -pp 1 \
        -vp None \
        -ep 4 \
        --hidden_size 1024 \
        --num_layers 24 \
        -mb 4 \
        --account "$SLURM_JOB_ACCOUNT" \
        --partition "$SLURM_JOB_PARTITION" \
        --log_dir "$NEMORUN_HOME" \
        --nemo_home "$NEMORUN_HOME/experiments" \
        --time_limit '"$STEP_TIMELIMIT"' \
        --packager none
'
rc=$?

## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether it stepped is verdict.sh's
## call. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

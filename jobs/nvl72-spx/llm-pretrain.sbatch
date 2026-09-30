#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH --segment=1
#SBATCH -t 0:30:00
#SBATCH --nice=20
## --nice 20 is the sweep's tier; higher is LATER. See
## docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/llm-pretrain.txt

## Llama 3.1 8B FP8, four-way data parallel across the tray -- the recipe
## llmb-run submits, frozen. Every value below was captured from a real
## submission and nothing here calls llmb-run. How to re-derive it when the
## recipe moves: docs/how-to/capture-an-sbatch-from-llmb-run.md.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=llm-pretrain
# shellcheck disable=SC2034
totalRuns=1

## Handed to srun --time below; #SBATCH -t is this plus a margin so the step
## limit fires first. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:20:00

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

## The version is not in the name we look for, so the other architecture's image
## has to be excluded by hand: it sorts FIRST, and pyxis reports the mismatch as
## `Exec format error`. See docs/explanation/containers.md#matching-the-architecture.
_other=x86
[[ "$(uname -m)" == x86_64 ]] && _other=arm
nemo_image() {
    local f
    for f in "$1"/nvidia+nemo+*.sqsh; do
        [[ -f "$f" && "$f" != *-"$_other".sqsh ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

## Node-local copy first, NFS as fallback. See docs/explanation/containers.md#why-local-images.
shared=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}
CONT=$(nemo_image "${NODE_CONTAINER_DIR:-/opt/containers}")
[[ -n "$CONT" ]] || CONT=$(nemo_image "$shared")

## An empty glob would reach srun as --container-image= and fail as something else.
[[ -n "$CONT" && -f "$CONT" ]] || {
    echo "no nvidia+nemo image for $(uname -m) in ${NODE_CONTAINER_DIR:-/opt/containers} or $shared"
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
    echo "the node cannot download the gated Llama files -- see docs/how-to/enable-llm-pretrain.md"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## The recipe's own environment, captured verbatim from the generated script.
## Why each one: docs/explanation/llmb.md#the-captured-environment.
export CUDA_DEVICE_MAX_CONNECTIONS=32
export NCCL_NVLS_ENABLE=0
export NVTE_FWD_LAYERNORM_SM_MARGIN=16
export NVTE_BWD_LAYERNORM_SM_MARGIN=16
export TOKENIZERS_PARALLELISM=False
export TORCH_NCCL_AVOID_RECORD_STREAMS=1
export TORCH_NCCL_HIGH_PRIORITY=1
export PYTHONUNBUFFERED=1

MOUNTS="${LLM_HF_HOME}:/hf-cache"

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
        --model_family_name llama \
        --model_recipe_name llama3_8b \
        --gpu gb300 \
        --container_image '"$CONT"' \
        --num_gpus 4 \
        --gpus_per_node 4 \
        --offline \
        --max_steps=50 \
        --custom_mounts=/hf-cache \
        --compute_dtype fp8_cs \
        --enable_pct_binding false \
        --config_variant v2 \
        --account "$SLURM_JOB_ACCOUNT" \
        --partition "$SLURM_JOB_PARTITION" \
        --log_dir "$NEMORUN_HOME" \
        --nemo_home "$NEMORUN_HOME/experiments" \
        --time_limit '"$STEP_TIMELIMIT"' \
        --packager none \
        train.manual_gc=true train.manual_gc_interval=100
'
rc=$?

## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether it stepped is verdict.sh's
## call. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

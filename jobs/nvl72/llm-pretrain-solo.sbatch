#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:30:00
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

## Node-local copy first, NFS as fallback. See docs/explanation/containers.md#why-local-images.
## The other architecture's image sorts FIRST and pyxis reports the mismatch as
## `Exec format error`, so it is excluded by name.
## See docs/explanation/containers.md#matching-the-architecture.
_other=x86
[[ "$(uname -m)" == x86_64 ]] && _other=arm
nemo_image() {
    local f
    for f in "$1"/nvidia+nemo+*.sqsh; do
        [[ -f "$f" && "$f" != *-"$_other".sqsh ]] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

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

## The sibling's recipe at scale 1. Why one GPU is a valid configuration:
## docs/explanation/llmb.md#running-below-the-characterised-scale.
LLMB_INSTALL=${LLMB_INSTALL:?not set -- launch_job.sh exports it; a bare sbatch must too}
WORKLOAD_DIR=$LLMB_INSTALL/workloads/pretrain_llama3.1
PERF_DIR=$WORKLOAD_DIR/Megatron-Bridge/scripts/performance

[[ -f "$PERF_DIR/run_script.py" ]] || {
    echo "no $PERF_DIR/run_script.py -- the recipe half of the llmb install is missing"
    echo "exit status: 1"
    echo FAIL
    exit 0
}

## A cache miss on a node with no route out must fail, not stall.
## See docs/explanation/llmb.md#running-offline.
export HF_HOME="${LLMB_HF:-$LLMB_INSTALL/.cache/huggingface}"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

## ── The four independent ranks ────────────────────────────────────────────
## Three things are load-bearing here and all three are explained in
## docs/explanation/llmb.md#keeping-the-four-solo-copies-independent: the
## per-rank CUDA_VISIBLE_DEVICES below (one GPU each), WORLD_SIZE=1 (stops NeMo
## forming one four-way group), and --label (the prefix verdict.sh parses).
unset CUDA_VISIBLE_DEVICES

## The recipe's own environment, the same block the sibling job carries.
## See docs/explanation/llmb.md#the-captured-environment.
export NCCL_NVLS_ENABLE=0
export NVTE_FWD_LAYERNORM_SM_MARGIN=16
export NVTE_BWD_LAYERNORM_SM_MARGIN=16
export TOKENIZERS_PARALLELISM=False
export TORCH_NCCL_AVOID_RECORD_STREAMS=1
export TORCH_NCCL_HIGH_PRIORITY=1
export PYTHONUNBUFFERED=1

## Not read-only: the recipe writes its experiment directory under --log_dir.
## An adopted install can keep its HF cache outside the install root, and a
## mount that does not cover HF_HOME is an offline cache miss inside the
## container. See docs/explanation/llmb.md#adopting-an-existing-install.
MOUNTS="${LLMB_INSTALL}:${LLMB_INSTALL}"
case "$HF_HOME" in
    "$LLMB_INSTALL"/*) ;;
    *) MOUNTS="${MOUNTS},${HF_HOME}:${HF_HOME}" ;;
esac

srun --time="$STEP_TIMELIMIT" --label --export=ALL \
        --ntasks=4 \
        --cpu-bind=cores \
        --container-image="${CONT}" \
        --container-mounts="${MOUNTS}" \
        --container-workdir=/tmp \
        --no-container-mount-home --container-writable \
        bash -c '
    export CUDA_VISIBLE_DEVICES=$SLURM_LOCALID
    export WORLD_SIZE=1 RANK=0 LOCAL_RANK=0
    ## One rendezvous per copy, or the four collide on one port with EADDRINUSE.
    ## See docs/explanation/llmb.md#keeping-the-four-solo-copies-independent.
    export MASTER_ADDR=127.0.0.1
    export MASTER_PORT=$(( 29500 + SLURM_LOCALID ))
    export CUDA_DEVICE_MAX_CONNECTIONS=1
    echo "gpu $SLURM_PROCID: $(nvidia-smi --query-gpu=uuid --format=csv,noheader)"
    ## The sibling recipe with --num_gpus 1, captured from a scale-1 submission.
    ## Single-process by construction: no torchrun, no distributed launcher.
    ## --cuda_graph_impl none is what makes it fit on one GPU; see
    ## docs/explanation/llmb.md#why-the-solo-job-turns-cuda-graphs-off.
    python '"$PERF_DIR"'/run_script.py \
        --model_family_name llama \
        --model_recipe_name llama3_8b \
        --gpu gb300 \
        --container_image '"$CONT"' \
        --num_gpus 1 \
        --gpus_per_node 4 \
        --cuda_graph_impl none \
        --offline \
        --max_steps=50 \
        --custom_mounts='"$HF_HOME"' \
        --compute_dtype fp8_cs \
        --enable_pct_binding false \
        --config_variant v2 \
        --account "$SLURM_JOB_ACCOUNT" \
        --partition "$SLURM_JOB_PARTITION" \
        --log_dir '"$WORKLOAD_DIR"' \
        --time_limit '"$STEP_TIMELIMIT"' \
        --packager none \
        train.manual_gc=true train.manual_gc_interval=100
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

#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 0:30:00
#SBATCH --nice=20
## --nice 20 is the sweep's tier; higher is LATER. See
## docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/cublasmatmul.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## GB300 single-node GEMM (GB200 uses hpl.sbatch), remediation-only: keep it out
## of `BENCHMARKS` and submit it by hand. See docs/reference/settings.md.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=cublasmatmul

## 2x DURATION. The step limit fires first, leaving the script alive to write
## its marker. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
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
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry alternative -- every node pulls it on first use. The `#` is enroot's
## registry/path separator.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## Per-GPU GEMM shape and duration -- adjust per the GB300 MOP for the platform
MATRIX_N=32768
DURATION=600

unset CUDA_VISIBLE_DEVICES

srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                cublasmatmul \
                    --n "${MATRIX_N}" \
                    --duration "${DURATION}"
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; quality is verdict.sh's call, read
## at status-check time. Its TFLOPS floor, VERDICT_MIN_TFLOPS_GEMM, is still 0
## for this platform. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero status here is srun's; `exit status: 0` means the
## verdict.sh gate failed it, which leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

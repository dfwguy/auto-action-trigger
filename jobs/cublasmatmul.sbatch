#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/cublasmatmul.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them. `unset CUDA_VISIBLE_DEVICES` below
## hands the tool every GPU the step holds -- which is none unless --gres says
## otherwise. --cpus-per-task is deliberately absent: it implies --exact and
## would shrink the step. See docs/benchmarks.md.

## AI Factory Testing Plan: single-node GEMM, remediation-only.
## GB300/B300 uses cuBlasMatMul; GB200 uses HPL (hpl.sbatch). Used to isolate a
## suspect node during remediation -- not part of the primary execution order,
## so leave this out of the `benchmarks=` list in actions/launch_job.sh and
## submit it by hand against the node under investigation.
## GB300 MOP 7.5.2.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=cublasmatmul

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

## Locally built image (build_containers.sh). The node-local copy that
## actions/file_copy.sh rsyncs to /tmp is preferred so job start does not read
## a multi-gigabyte image over NFS; the shared directory is the fallback for a
## node the rsync has not reached yet. See docs/containers.md.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
## Registry alternative -- every node pulls it over the network on first use.
## Note the enroot `#` separator between registry host and image path.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## Per-GPU GEMM shape and duration -- adjust per the GB300 MOP for the platform
MATRIX_N=32768
DURATION=600

unset CUDA_VISIBLE_DEVICES

srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                cublasmatmul \
                    --n "${MATRIX_N}" \
                    --duration "${DURATION}"


## ------------- parse info starts here ----------- ##
## Compare per-GPU TFLOPS against the platform floor and flag any GPU that
## reports an error. Set GEMM_MIN_TFLOPS per platform before use.
##
## GEMM_MIN_TFLOPS is 0 until the floor for this platform is established, which
## makes the `low` check a no-op -- so the run has to be gated on there being
## TFLOPS readings at all. One per GPU is expected; requiring at least one
## keeps a job that never produced a number from reporting DONE.

GEMM_MIN_TFLOPS=0
GEMM_MIN_READINGS=1

readings=$(grep -oiE "[0-9]+(\.[0-9]+)?[[:space:]]*TFLOPS" "$RESULT_FILE" \
        | grep -oE "^[0-9]+(\.[0-9]+)?")
count=$(printf '%s\n' "$readings" | grep -c .)

errors=$(grep -iE "error|fail|mismatch|srun: error" "$RESULT_FILE")
low=$(printf '%s\n' "$readings" | awk -v min="$GEMM_MIN_TFLOPS" 'NF && $1 < min')

if [[ -n "$RESULT_FILE" && -z "$errors" && -z "$low" && "$count" -ge "$GEMM_MIN_READINGS" ]];
then
	echo DONE
else
	echo FAIL
fi

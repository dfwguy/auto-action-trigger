#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/cublasmatmul.txt

## AI Factory Testing Plan: single-node GEMM, remediation-only.
## GB300/B300 uses cuBlasMatMul; GB200 uses HPL (hpl.sbatch). Used to isolate a
## suspect node during remediation -- not part of the primary execution order,
## so leave this out of the `benchmarks=` list in actions/launch_job.sh and
## submit it by hand against the node under investigation.
## GB300 MOP 7.5.2.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=cublasmatmul

## ------------- job info starts here ------------- ##

## Locally built image (build_containers.sh). The node-local copy that
## actions/file_copy.sh rsyncs to /tmp is preferred so job start does not read
## a multi-gigabyte image over NFS; the shared directory is the fallback for a
## node the rsync has not reached yet. See BUILD_CONTAINERS.md.
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

GEMM_MIN_TFLOPS=0

errors=$(grep -iE "error|fail|mismatch" "$RESULT_FILE")
low=$(grep -oiE "[0-9]+(\.[0-9]+)?[[:space:]]*TFLOPS" "$RESULT_FILE" \
        | grep -oE "^[0-9]+(\.[0-9]+)?" \
        | awk -v min="$GEMM_MIN_TFLOPS" '$1 < min')

if [[ -z "$errors" && -z "$low" ]];
then
	echo DONE
else
	echo FAIL
fi

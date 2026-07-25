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

## Upstream image -- pulled by enroot/pyxis at job start, nothing to build.
## Note the enroot `#` separator between registry host and image path.
CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
## Local import alternative (see MAKE_CONTAINERS.md):
#CONT=/home/cmods/bringup/containers/nvidia+hpc-benchmarks+26.02.sqsh

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

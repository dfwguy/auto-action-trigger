#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 4:10:00
#SBATCH --nice=20
## The sweep's tier; higher is later. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/stream.txt

## No --gres, this job never touches a GPU. Steps inherit only what was
## explicitly requested; no --cpus-per-task, it implies --exact and would shrink
## the core count OMP_NUM_THREADS reads.
## See docs/reference/jobs.md#the-allocation-header.

## AI Factory Testing Plan: STREAM -- SNT2 (Exhaustive)

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=stream

## 2x the plan's ~1-2 hr STREAM + Memtester row, upper end. Fires before
## #SBATCH -t: docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=4:00:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds; only a step can see that. Wording is fixed -- verdict.sh
## greps this file. See docs/reference/jobs.md#preflight and example.sbatch.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## STREAM ships in the HPC-Benchmarks image; stream-cpu-test.sh is Arm SBSA only.
## Node-local rsynced copy first, NFS fallback. See docs/explanation/containers.md#why-local-images.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry fallback; note enroot's `#` separator. Every node pulls on first use.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## One OpenMP thread per core, threads pinned across all NUMA nodes
OMP_NUM_THREADS=$(nproc)
export OMP_NUM_THREADS
export OMP_PROC_BIND=spread
export OMP_PLACES=cores

## The Triad floor lives in verdict.sh as VERDICT_MIN_TRIAD_MBS, so raising it
## re-judges old results. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 --cpu-bind=none \
                --container-image="${CONT}" \
                ./stream-cpu-test.sh
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh judges the result.
## A FAIL with `exit status: 0` therefore came from verdict.sh, not from srun.
## See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

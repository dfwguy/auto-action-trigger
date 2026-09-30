#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## The sweep's tier: higher is later, behind the dcgmi gates at 0 and ahead of
## burn-in at 100000. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/alltoall.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## Used in the status line; read out of this file's text, never sourced.
# shellcheck disable=SC2034
job_name=alltoall

## 2x the plan's estimate, floored at 15 min. The step limit fires first, which
## leaves the batch script alive to write its marker -- see
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:15:00
## Read out of this file's text by grep, never sourced.
# shellcheck disable=SC2034
totalRuns=1


## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, asked from inside a step because the job's AllocTRES
## cannot answer it. The passing line's wording is fixed -- the parse block
## below and verdict.sh grep this same file. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}



## The node-local copy is preferred so job start does not read a multi-gigabyte
## image over NFS; the shared directory is the fallback for a node the rsync has
## not reached yet. See docs/explanation/containers.md#why-local-images.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry alternative, pulled per node on first use. Note enroot's `#`
## separator between registry host and image path.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
#HPLDATPATH=$BRINGUP_HOME/jobs/nvl72/hpl/

export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
#export NCCL_P2P_LEVEL=NVL
export NCCL_NVLS_ENABLE=1
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=0


## No --ntasks-per-node here on purpose: srun inherits the 4 from the #SBATCH
## header, and stating it twice let the two drift. `-g 1` gives one rank per GPU.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                alltoall_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is any good is
## decided by verdict.sh. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
## /dev/infiniband is deliberately not mounted -- this job is NVLink scope.

## A FAIL with a non-zero status here is the job's own; a FAIL with `exit
## status: 0` came from the gate in verdict.sh, which leaves no trace here.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



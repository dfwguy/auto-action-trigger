#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## --nice 20 is the sweep's tier; higher is later. See
## docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/alltoall-nonvlink.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## AI Factory Testing Plan: NCCL AllToAll -- Single Node, No NVLink -- SNT2
## GB300 MOP 7.3 Scope A. NVLink-scope counterpart: alltoall.sbatch

## shellcheck disable: read by grep from other scripts, never sourced.
# shellcheck disable=SC2034
job_name=alltoall-nonvlink

## Handed to srun --time below, so the step is cancelled and the batch script
## survives. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:15:00
## shellcheck disable: read by grep from this file's text, never sourced.
# shellcheck disable=SC2034
totalRuns=1

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. Wording of the
## passing line is fixed; verdict.sh greps this file. See
## docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}



## Node-local copy first so job start does not stream the image over NFS. See
## docs/explanation/containers.md#how-the-caching-works.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry fallback; note enroot's `#` separator. docs/explanation/containers.md#why-local-images.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## bond0 carries bootstrap and the IB OOB handshake only, never collective data.
export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO

## Exclude every on-node shortcut so traffic is pushed out to the HCAs
export NCCL_P2P_DISABLE=1
export NCCL_SHM_DISABLE=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=0
export NCCL_IB_DISABLE=0

## Deletes NCCL's silent fallback to TCP: no usable HCA is now an init failure
## rather than a clean but worthless result. See
## docs/explanation/judging-benchmarks.md#judge-the-channels-never-the-plugin-registration
export NCCL_NET=IB

## Compute-plane HCA discovery, shared with allreduce-nonvlink.sbatch. See
## jobs/nvl72/nccl-hca.sh for what is filtered out and why.
HCA_LIB=${BRINGUP_HOME:?not set -- launch_job.sh exports it; a bare sbatch must too}/jobs/nvl72/nccl-hca.sh
if [[ ! -f "$HCA_LIB" ]]; then
	echo "Missing $HCA_LIB -- cannot work out which HCAs to run over."
	echo FAIL
	exit 1
fi
# shellcheck source=/dev/null
source "$HCA_LIB"

## Fail here rather than let NCCL_IB_HCA="" mean "any HCA, including the ones
## just excluded".
if ! nccl_hca_detect; then
	echo "No compute-plane HCA found on $(hostname). Nothing to run this test over."
	echo FAIL
	exit 1
fi
nccl_hca_report_host

## Ask the container what it sees; a healthy host list proves nothing. See
## docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas. --ntasks=1, not
## --ntasks-per-node=1, which Slurm ignores in favour of the header's 4.
srun --ntasks=1 --export=ALL \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                bash -c "$NCCL_HCA_PROBE"


## No --ntasks-per-node: srun inherits the header's 4, and stating it twice let
## them drift. `-g 1` pairs with 4 tasks for one rank per GPU.
## /dev/infiniband must be mounted -- enroot's fresh /dev has no HCA character
## devices. docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                alltoall_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
## `exit status:` says who decided a FAIL -- non-zero is the job's own, 0 means
## the gate in verdict.sh rejected output that ran clean.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

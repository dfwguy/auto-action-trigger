#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:8
#SBATCH --ntasks-per-node=8
#SBATCH -t 0:25:00
#SBATCH --nice=20
## The sweep's tier; higher is later. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/allreduce-nonvlink.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## SNT2, GB300 MOP 7.3 Scope A: intra-node collectives forced over the HCAs,
## NVLink excluded. NVLink-scope counterpart: allreduce.sbatch

## Used in the status line. Read out of this file's text by grep, never sourced.
# shellcheck disable=SC2034
job_name=allreduce-nonvlink

## 2x the plan's < 5 min for single-node NCCL, floored at 15 min. Cancelling
## the step leaves the script alive to write its marker; see
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:15:00
## Read out of this file's text by grep, never sourced -- see example.sbatch.
# shellcheck disable=SC2034
totalRuns=1

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, which only a step can see. The passing line's wording
## is fixed -- verdict.sh greps this same file. See
## docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 8 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}



## The node-local copy first so job start does not read a multi-gigabyte image
## over NFS; shared directory is the fallback. See
## docs/explanation/containers.md#why-local-images.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry fallback by hand; note enroot's `#` separator.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## bond0 is out-of-band only -- bootstrap and the IB OOB handshake, never
## collective data.
export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO

## Exclude every on-node shortcut so traffic is pushed out to the HCAs
export NCCL_P2P_DISABLE=1
export NCCL_SHM_DISABLE=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=0
export NCCL_IB_DISABLE=0

export NCCL_IB_TC=96
export NCCL_IB_GID_INDEX=3
export UCX_IB_GID_INDEX=3
export NCCL_IB_ADAPTIVE_ROUTING=1

export NCCL_NET_PLUGIN=/opt/hpcx/nccl_spectrum-x_plugin/lib/libnccl-net-spcx.so
export NCCL_PLUGIN_PATH=/opt/hpcx/nccl_spectrum-x_plugin/lib
export LD_LIBRARY_PATH=/opt/hpcx/nccl_spectrum-x_plugin/lib:$LD_LIBRARY_PATH

## Excluding the shortcuts does not say which network. Without this, no visible
## HCA silently means TCP over bond0 and a clean-looking summary. See
## docs/explanation/judging-benchmarks.md#judge-what-the-tool-means-not-what-it-says.
export NCCL_NET=SPCX

## Compute-plane HCA discovery, shared with alltoall-nonvlink.sbatch. See that
## file for what is filtered out, and
## docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
HCA_LIB=${BRINGUP_HOME:?not set -- launch_job.sh exports it; a bare sbatch must too}/jobs/b300-spx/nccl-hca.sh
if [[ ! -f "$HCA_LIB" ]]; then
	echo "Missing $HCA_LIB -- cannot work out which HCAs to run over."
	echo FAIL
	exit 1
fi
# shellcheck source=/dev/null
source "$HCA_LIB"

## Better than letting NCCL_IB_HCA="" mean "any HCA, including the excluded".
if ! nccl_hca_detect; then
	echo "No compute-plane HCA found on $(hostname). Nothing to run this test over."
	echo FAIL
	exit 1
fi
nccl_hca_report_host

## Ask the container what it sees, not the host -- see
## docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas. --ntasks=1 rather than
## --ntasks-per-node=1, which Slurm ignores in favour of the header's 8.
srun --ntasks=1 --export=ALL \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                bash -c "$NCCL_HCA_PROBE"


## No --ntasks-per-node here on purpose: srun inherits the header's 8, and
## stating it twice let them drift. `-g 1` pairs with those 4 to cover 4 GPUs.
## /dev/infiniband must be mounted in -- enroot's fresh /dev omits the HCA
## character devices, while /sys comes along with the host bind mount.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                all_reduce_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## srun's status is the one thing the log cannot recover afterwards -- a run
## can print a valid summary and still lose a rank on the way out. A FAIL with
## `exit status: 0` therefore came from verdict.sh, not from the job.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

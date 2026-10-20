#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## The sweep's tier; higher is later. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/alltoall-nonvlink-pytorch.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## alltoall forced over the HCAs, NVLink excluded, in the pytorch image. hpc-benchmarks counterpart: alltoall-nonvlink.sbatch

## Used in the status line. Read out of this file's text by grep, never sourced.
# shellcheck disable=SC2034
job_name=alltoall-nonvlink-pytorch

## Cancelling the step leaves the script alive to write its marker; see
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
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## The node-local copy first so job start does not read a multi-gigabyte image
## over NFS; shared directory is the fallback. See
## docs/explanation/containers.md#why-local-images.
IMG=nvidia+pytorch+26.08-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry fallback by hand; note enroot's `#` separator.
#CONT=docker://nvcr.io#nvidia/pytorch:26.08-py3

## Everything the step needs, exported below and named in --container-env so the
## image's own values do not win.
env_pairs=(
    ## The PMIx/MPI lines may be needed in this image -- the capture in issue #21
    ## carried them. Left off until a run shows it; if the job passes without
    ## them, delete the block.
    #PMIX_MCA_psec=native
    #PMIX_MCA_gds=hash
    #OMPI_MCA_pml=ob1
    #"OMPI_MCA_btl=tcp,self,vader"
    #OMPI_MCA_btl_tcp_if_include=bond0
    #OMPI_MCA_oob_tcp_if_include=bond0
    #OMPI_MCA_coll_ucc_enable=0
    #OMPI_MCA_coll_hcoll_enable=0
    NCCL_SOCKET_IFNAME=bond0
    NCCL_DEBUG=INFO
    NCCL_P2P_DISABLE=1
    NCCL_SHM_DISABLE=1
    NCCL_NVLS_ENABLE=0
    NCCL_MNNVL_ENABLE=0
    NCCL_IB_DISABLE=0
    NCCL_NET=IB
)
# shellcheck disable=SC2163  # each element is a NAME=value pair, which export takes whole
for kv in "${env_pairs[@]}"; do export "$kv"; done
## One list for the exports and for --container-env, so the two cannot drift.
container_env=$(printf '%s\n' "${env_pairs[@]%%=*}" | paste -sd,)

## Compute-plane HCA discovery, shared with the hpc-benchmarks -nonvlink jobs.
## See docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
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
container_env+=,NCCL_IB_HCA

## Ask the container what it sees, not the host. --ntasks=1, not
## --ntasks-per-node=1, which Slurm ignores in favour of the header's 4.
srun --ntasks=1 --export=ALL \
                --container-image="${CONT}" \
                --container-env="$container_env" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                bash -c "$NCCL_HCA_PROBE"


## No --ntasks-per-node here on purpose: srun inherits the header's 4, and
## stating it twice let them drift. `-g 1` pairs with those 4 for one rank per GPU.
## /dev/infiniband must be mounted -- enroot's fresh /dev omits the HCA character devices.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                --container-env="$container_env" \
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

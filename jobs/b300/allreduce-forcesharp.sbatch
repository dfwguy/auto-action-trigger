#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:8
#SBATCH --ntasks-per-node=8
#SBATCH -t 0:25:00
#SBATCH --nice=20
## 20 is the sweep's tier; higher is later. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/allreduce-forcesharp.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## NCCL AllReduce, single node, NVLink, SHARP forced -- allreduce.sbatch with
## the NVSwitch offload made mandatory, so this asks "did SHARP run" rather than
## "was it allowed". See
## docs/explanation/judging-benchmarks.md#judge-what-the-tool-means-not-what-it-says.

## Job name is used in the status line.
# shellcheck disable=SC2034  # read by grep out of this file, never sourced
job_name=allreduce-forcesharp

## Step limit fires before #SBATCH -t so the script survives to write a marker.
## See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:15:00
# shellcheck disable=SC2034  # read by grep out of this file, never sourced
totalRuns=1

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. The wording of
## these lines is fixed; verdict.sh greps this file. See
## docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 8 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}



## Node-local copy first, NFS as the fallback. See
## docs/explanation/containers.md#why-local-images.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry alternative -- every node pulls over the network on first use. The
## `#` is enroot's registry/path separator.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
#HPLDATPATH=$BRINGUP_HOME/jobs/nvl72/hpl/

export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
#export NCCL_P2P_LEVEL=NVL

## Permits the NVSwitch offload; on its own it still falls back silently.
export NCCL_NVLS_ENABLE=1

## This line, not the one above, is what makes this job different: pinning the
## algorithm turns an unsupported node into an ncclCommInitRank failure instead
## of a quiet Ring run. Suspect it first if this fails fleet-wide after an image
## change. See docs/explanation/judging-benchmarks.md#judge-what-the-tool-means-not-what-it-says.
export NCCL_ALGO=NVLS
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=0


## No --ntasks-per-node here on purpose: srun inherits the 8 from the header,
## and stating it in both places let them drift. `-g 1` is one rank per GPU.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                all_reduce_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is good is
## verdict.sh's call, re-read on every status check. See
## docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
##
## /dev/infiniband is deliberately not mounted, unlike the -nonvlink jobs: this
## is the NVLink scope, and reachable HCAs would let a run that lost NVLink
## quietly succeed over IB.

## A FAIL with a non-zero status here is the job's own; `exit status: 0` means
## the gate in verdict.sh rejected it.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



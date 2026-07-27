#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/alltoall-nonvlink.txt

## Allocation. --exclusive is a JOB-level guarantee, and a step inherits only
## what was explicitly requested -- never what the job was implicitly granted.
## So --gres and --mem=0 are stated even though --exclusive is supposed to
## cover them, and --cpus-per-task is deliberately absent: it implies --exact
## and would shrink every srun below to that core count. See the allocation
## header section of docs/benchmarks.md.

## AI Factory Testing Plan: NCCL AllToAll -- Single Node, No NVLink -- SNT2
## Intra-node GPU collectives forced over the HCAs (GB300 MOP 7.3 Scope A,
## loopback east/west fabric with NVLink excluded).
## NVLink-scope counterpart: alltoall.sbatch

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=alltoall-nonvlink

## Step time limit, handed to srun --time below: 2x the plan's < 5 min for
## single-node NCCL, floored at 15 min.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=0:15:00
totalRuns=1

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

## bond0 is the out-of-band interface only -- bootstrap and the IB OOB
## handshake. It is not where collective data goes. Confusing the two is what
## let this job run entirely over TCP without anyone noticing.
export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO

## Exclude every on-node shortcut so traffic is pushed out to the HCAs
export NCCL_P2P_DISABLE=1
export NCCL_SHM_DISABLE=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=0
export NCCL_IB_DISABLE=0

## Disabling the shortcuts only says "go to the network"; it does not say which
## one. With no HCA visible NCCL logs `NET/IB : No device found.`, drops to
## `NET/Socket : Using [0]bond0`, and the run still prints a clean summary --
## which is how this passed for weeks at ~1 GB/s bus bandwidth over TCP.
## NCCL_NET=IB deletes the fallback: no usable HCA is now an init failure
## rather than a quietly meaningless result.
export NCCL_NET=IB

## Compute-plane HCA discovery lives in jobs/nvl72/nccl-hca.sh. This file and
## allreduce-nonvlink.sbatch carried byte-identical copies of it, so ab9121d had
## to make the same edit twice. See that file for what is filtered out and why.
HCA_LIB=/home/cmods/bringup/jobs/nvl72/nccl-hca.sh
if [[ ! -f "$HCA_LIB" ]]; then
	echo "Missing $HCA_LIB -- cannot work out which HCAs to run over."
	echo FAIL
	exit 1
fi
source "$HCA_LIB"

## Better to say so here than to let NCCL_IB_HCA="" mean "any HCA, including
## the ones we just excluded" -- or to spend an hour of walltime discovering it.
if ! nccl_hca_detect; then
	echo "No compute-plane HCA found on $(hostname). Nothing to run this test over."
	echo FAIL
	exit 1
fi
nccl_hca_report_host

## What the host sees is not the question being asked. NCCL calls
## ibv_get_device_list from inside the container, and enroot gives the container
## a fresh /dev -- so the host list can be complete and correct while the
## container sees nothing at all. That is exactly what happened here, and it is
## precisely what checking by hand over ssh cannot show, because ssh puts you on
## the host. Ask the container directly, before spending an hour of walltime
## finding out from the bandwidth.
##
## --ntasks=1 rather than --ntasks-per-node=1: the header already asked for 4,
## and Slurm resolves the per-node form by warning `can't honor
## --ntasks-per-node set to 1` and running 4 anyway, which would print all of
## this four times.
srun --ntasks=1 --export=ALL \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                bash -c "$NCCL_HCA_PROBE"


## No --ntasks-per-node here on purpose: srun inherits the 4 from the #SBATCH
## header above. Setting it in both places let them drift -- the header asked
## for 4 and srun asked for 1, which Slurm resolves by warning `can't honor
## --ntasks-per-node set to 1` and running 4 anyway. One rank per GPU, so `-g 1`
## pairs with 4 tasks to cover all 4 GPUs.
##
## /dev/infiniband is mounted in because enroot gives the container a fresh
## /dev, so the HCA character devices are absent unless asked for. That single
## omission is what made ibv_get_device_list return nothing and sent the whole
## benchmark over bond0. /sys/class/infiniband comes along with the host /sys
## enroot already bind-mounts, so only /dev needs saying.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                --container-mounts=/dev/infiniband:/dev/infiniband \
                alltoall_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## srun's exit status is the one thing that cannot be recovered from the log
## afterwards: a run can print a complete, valid summary and still have a rank
## die on the way out.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

#!/bin/bash
#SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/allreduce-nonvlink.txt

## AI Factory Testing Plan: NCCL AllReduce -- Single Node, No NVLink -- SNT2
## Intra-node GPU collectives forced over the HCAs (GB300 MOP 7.3 Scope A,
## loopback east/west fabric with NVLink excluded). Confirms the in-system
## network is configured correctly and performant.
## NVLink-scope counterpart: allreduce.sbatch

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=allreduce-nonvlink
totalRuns=1

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

export NCCL_SOCKET_IFNAME=enP22p3s0f0np0
export NCCL_DEBUG=INFO

## Exclude every on-node shortcut so traffic is pushed out to the HCAs
export NCCL_P2P_DISABLE=1
export NCCL_SHM_DISABLE=1
export NCCL_NVLS_ENABLE=0
export NCCL_MNNVL_ENABLE=0
export NCCL_IB_DISABLE=0


srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                all_reduce_perf_mpi -b 8 -e 16G -f 2 -g 1


## ------------- parse info starts here ----------- ##

status=$(grep -iE "code 1" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

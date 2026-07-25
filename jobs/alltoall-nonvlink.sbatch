#!/bin/bash
#SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/alltoall-nonvlink.txt

## AI Factory Testing Plan: NCCL AllToAll -- Single Node, No NVLink -- SNT2
## Intra-node GPU collectives forced over the HCAs (GB300 MOP 7.3 Scope A,
## loopback east/west fabric with NVLink excluded).
## NVLink-scope counterpart: alltoall.sbatch

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=alltoall-nonvlink
totalRuns=1

## ------------- job info starts here ------------- ##



## Upstream image -- pulled by enroot/pyxis at job start, nothing to build.
## Note the enroot `#` separator between registry host and image path.
CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
## Local import alternative (see MAKE_CONTAINERS.md):
#CONT=/home/cmods/bringup/containers/nvidia+hpc-benchmarks+26.02.sqsh

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
                alltoall_perf_mpi -b 8 -e 16G -f 2 -g 1


## ------------- parse info starts here ----------- ##

status=$(grep -iE "code 1" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

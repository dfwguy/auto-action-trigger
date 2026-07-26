#!/bin/bash
#SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/allreduce.txt

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=allreduce
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
#HPLDATPATH=/home/cmods/bringup/jobs/hpl/

export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
#export NCCL_P2P_LEVEL=NVL
export NCCL_NVLS_ENABLE=1
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=0


srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                alltoall_perf_mpi -b 8 -e 16G -f 2 -g 1 
#                --dat /hpldat/hpl${SLURM_NNODES}N.dat 
#                --mem-affinity 0:0:1:1 \
#                --cpu-affinity 0-35:36-71:72-107:108-143 \
#                --gpu-affinity 0:1:2:3
#		--ucx-affinity roce_r0:roce_r1:roce_r2:roce_r3

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000


## ------------- parse info starts here ----------- ##

status=$(grep -iE "code 1" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi



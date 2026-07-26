#!/bin/bash
##SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --gpus-per-node=1
##SBATCH -o /home/cmods/bringup/results/%N/hpl.txt
#
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
HPLDATPATH=/home/cmods/bringup/jobs/hpl/

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=hpl

## ------------- job info starts here ------------- ##

#hosts=($(scontrol show hostnames $SLURM_JOB_NODELIST))

#generate HPLDAT
#./scripts/gen_hpldat_gb200.sh ${SLURM_NNODES} > ./hpldat/hpl${SLURM_NNODES}N.dat

#sleep 2

#ssh ${hosts[0]} nvidia-imex-ctl -N

#srun --ntasks-per-node=1 ./collect-power.sh
#srun --ntasks-per-node=1 ./set-cpufreq.sh 2000000
#srun --ntasks-per-node=1 nvidia-smi -pl $i -sc 1

#srun --container-image="{CONT}" --container-mounts="${HPLDATPATH}:/hpldat" hostname
#srun --container-image="{CONT}" hostname

srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" --container-mounts="${HPLDATPATH}:/hpldat" \
                /workspace/hpl.sh \
                --dat /hpldat/hpl${SLURM_NNODES}N.dat 
#                --mem-affinity 0:0:1:1 \
#                --cpu-affinity 0-35:36-71:72-107:108-143 \
#                --gpu-affinity 0:1:2:3
#		--ucx-affinity roce_r0:roce_r1:roce_r2:roce_r3

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000

## ------------- parse info starts here ----------- ##


status=$(grep "PASSED" "$RESULT_FILE")

if [[ ! -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi




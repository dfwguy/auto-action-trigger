#!/bin/bash
##SBATCH -p defq
##SBATCH --exclusive
##SBATCH -N1
#SBATCH --gpus-per-node=1
##SBATCH -o /home/cmods/bringup/results/%N/hpl.txt
#
CONT=/home/cmods/bringup/containers/nvidia+hpc-benchmarks+26.02.sqsh
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




#!/bin/bash
#SBATCH -N 1
##SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/dcgm.txt

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm

## ------------- job info starts here ------------- ##
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
dcgmi diag -r 3


## ------------- parse info starts here ----------- ##

status=$(grep -iE "fail|warn|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi





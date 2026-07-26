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
## `dcgmi diag` prints a results table of `| <test> | Pass |` rows on a clean
## run. Requiring at least one is what distinguishes a passing diagnostic from
## one that never ran -- no dcgmi binary, nv-hostengine down, no GPUs visible.
## Without it the error grep alone reports DONE for empty output.

passes=$(grep -cE "\|[[:space:]]*Pass[[:space:]]*\|" "$RESULT_FILE")
status=$(grep -iE "fail|warn|error" "$RESULT_FILE")

if [[ -n "$RESULT_FILE" && -z "$status" && "$passes" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi





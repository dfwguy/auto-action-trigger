#!/bin/bash
#SBATCH -N 1
#SBATCH -t 0:30:00
## See dcgm.sbatch: dcgmi takes every GPU, so the allocation must claim them or
## Slurm will co-schedule a GPU job on top of it.
#SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/dcgm-r2.txt

## AI Factory Testing Plan: DCGM Diagnostics (`dcgmi -r 2`) -- SNT2
## Time to Market gate (medium, ~2 min). `-r 3` is the Hybrid gate (dcgm.sbatch),
## `-r 4` is the Exhaustive gate (dcgm-r4.sbatch).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm-r2

## ------------- job info starts here ------------- ##
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
dcgmi diag -r 2


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

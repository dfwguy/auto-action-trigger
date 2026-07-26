#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 3:00:00
##SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/dcgm-r4.txt

## AI Factory Testing Plan: DCGM Diagnostics (`dcgmi -r 4`) -- SNT2
## Exhaustive gate (extended stress, ~45-90 min). `-r 2` is the TTM gate
## (dcgm-r2.sbatch), `-r 3` is the Hybrid gate (dcgm.sbatch).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm-r4

## ------------- job info starts here ------------- ##
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
dcgmi diag -r 4
rc=$?


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

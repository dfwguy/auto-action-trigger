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
rc=$?


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

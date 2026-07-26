#!/bin/bash
#SBATCH -N 1
## `unset CUDA_VISIBLE_DEVICES` below hands dcgmi every GPU on the node, so the
## allocation has to claim them. Left commented out this reads to Slurm as a
## GPU-free job and a 4-GPU NCCL job is placed alongside it -- dcgmi's memory
## and stress plugins take most of the framebuffer, and the collective dies
## allocating its test buffers.
#SBATCH --gpus-per-node=4
##SBATCH -o /home/cmods/bringup/results/%N/dcgm.txt

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm

## ------------- job info starts here ------------- ##
unset CUDA_VISIBLE_DEVICES
#export CUDA_VISIBLE_DEVICES=0,1,2,3

#module load cuda-dcgm
dcgmi diag -r 3
rc=$?


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

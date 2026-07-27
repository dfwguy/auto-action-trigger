#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
## `unset CUDA_VISIBLE_DEVICES` below hands dcgmi every GPU on the node, so the
## allocation has to claim them. --exclusive is not enough on its own: it grants
## the GPUs to the JOB, but a step inherits only what was explicitly requested,
## so without this line the srun sees zero GPUs. Dropping it entirely also reads
## to Slurm as a GPU-free job -- dcgmi's memory and stress plugins take most of
## the framebuffer, and anything co-scheduled dies allocating its buffers.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
##SBATCH -o /home/cmods/bringup/results/%N/dcgm.txt

## --cpus-per-task is deliberately absent throughout: it implies --exact and
## would shrink the step to that core count. See docs/benchmarks.md.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}
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

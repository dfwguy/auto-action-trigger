#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH -t 3:00:00
## See dcgm.sbatch: dcgmi takes every GPU, so the allocation must claim them --
## --exclusive grants them to the job but the step inherits only what was
## explicitly requested here. This line was commented out before, which the
## batch body got away with -- `dcgmi diag` runs there, not in a step, and an
## --exclusive job body does see every GPU. The preflight srun below does not,
## and neither would anything else moved into a step later.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
##SBATCH -o /home/cmods/bringup/results/%N/dcgm-r4.txt

## AI Factory Testing Plan: DCGM Diagnostics (`dcgmi -r 4`) -- SNT2
## Exhaustive gate (extended stress, ~45-90 min). `-r 2` is the TTM gate
## (dcgm-r2.sbatch), `-r 3` is the Hybrid gate (dcgm.sbatch).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=dcgm-r4

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
dcgmi diag -r 4
rc=$?


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

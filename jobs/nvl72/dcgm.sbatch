#!/bin/bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH -t 0:50:00
## `unset CUDA_VISIBLE_DEVICES` below hands dcgmi every GPU on the node, so the
## allocation has to claim them. --exclusive is not enough on its own: it grants
## the GPUs to the JOB, but a step inherits only what was explicitly requested,
## so without this line the srun sees zero GPUs. Dropping it entirely also reads
## to Slurm as a GPU-free job -- dcgmi's memory and stress plugins take most of
## the framebuffer, and anything co-scheduled dies allocating its buffers.
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH --nice=0
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. The dcgm gates sit at 0 because they are fast and
## decide whether the rest of the sweep is worth running at all; the rest of
## BENCHMARKS is 20 and burn-in is 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/dcgm.txt

## --cpus-per-task is deliberately absent throughout: it implies --exact and
## would shrink the step to that core count. See docs/benchmarks.md.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=dcgm

## Deadline: 2x ~20 min, the plan's estimate for dcgmi -r 3.
##
## Applied with `timeout` rather than with `srun --time` as every other job
## does, because dcgmi runs in the batch script body rather than in an srun
## step -- deliberately, so it sees the job's GPUs without restating --gres --
## and there is no step for --time to bound. `timeout` is the equivalent for a
## command that is not a step: it bounds the workload while leaving the batch
## script alive to write its marker, which is the property that matters.
## #SBATCH -t above is this plus a margin, so this fires first.
##
## Without it, an overrunning dcgmi is SIGKILLed by the job walltime with no
## marker written, which verdict.sh reads as INCOMPLETE -- a node that gets
## re-queued every sweep and never converges. See example.sbatch.
JOB_TIMEOUT=40m

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
##
## TERM first so dcgmi can tear down its host engine connection; KILL 60s later
## for one that will not go. `timeout` reports 124 when the command took the
## TERM and exited, but 137 when it ignored it and the KILL had to fire -- and
## an ignored TERM is exactly what a wedged diagnostic does, so both count.
timeout --signal=TERM --kill-after=60 "$JOB_TIMEOUT" dcgmi diag -r 3
rc=$?

## In a fixed wording verdict.sh matches. A job killed on the clock that writes
## nothing about it leaves the reader guessing whether the node died or the
## time ran out -- the silence docs/architecture.md warns about.
[[ "$rc" -eq 124 || "$rc" -eq 137 ]] && echo "timeout: killed after ${JOB_TIMEOUT}"


## ------------- parse info starts here ----------- ##
## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 1:00:00

## Allocation. This is the template every other job is copied from, so the
## header shape matters as much as the parse block does.
##
## --exclusive is a JOB-level guarantee. A step inherits only what was
## EXPLICITLY requested, never what the job was implicitly granted:
##
##   --exclusive alone          job gets every GPU, the step gets none
##   --exclusive --gres=gpu:4   job and step both get 4
##   --exclusive --mem=0        memory is never implied either -- say it
##   --exclusive -c 32          -c implies --exact, so the step gets 32 cores
##                              out of an allocation holding all of them
##
## Hence: state --gres and --mem=0 even though --exclusive supposedly covers
## them, and leave --cpus-per-task out. If a job does need it, re-state it on
## the srun or export SRUN_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK}", and keep
## ntasks-per-node x cpus-per-task equal to the node's core count or cores sit
## stranded inside an exclusive allocation. See docs/benchmarks.md.
##
## --exclusive is also what serializes the sweep: one job per node at a time,
## enforced by the scheduler on resources rather than by a shared job name.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=example
totalRuns=1

## ------------- job info starts here ------------- ##

## ── Preflight ─────────────────────────────────────────────────────────────
## What the STEP actually holds, asked from inside a step. This is the check
## every other job carries, and the reasoning is here rather than repeated in
## each one.
##
## The job's AllocTRES cannot answer this question. A step is a different
## cgroup from the batch script body, and --exclusive grants the job resources
## that a step does not inherit unless they were requested by name -- so
## `scontrol show job` can read cpu=144,gres/gpu=4 while the training process
## sees no GPU at all. Checking from the batch body is the same mistake one
## level up. Ask the workload's own cgroup.
##
## `grep -c "^GPU"` rather than `nvidia-smi -L | wc -l`: the latter counts an
## error message as a GPU, so a node with no driver reads as healthy.
##
## --ntasks=1, not --ntasks-per-node=1 -- the header already asked for 4, and
## Slurm resolves the per-node form by warning `can't honor --ntasks-per-node
## set to 1` and running 4 anyway, printing all of this four times.
##
## Cores are compared against SLURM_CPUS_ON_NODE, what the job was granted,
## rather than against the node's physical count. A site reserving cores
## (CoreSpecCount) would fail every job on the second comparison, and a
## preflight that drains the cluster is worse than no preflight.
##
## The passing line's wording is load-bearing: the parse block below and
## verdict.sh grep this same file, several of them case-insensitively for
## fail/warn/error/N-A. It also must not begin with a digit, or the nccl-tests
## per-size parser in verdict.sh reads it as a data row. The GPU count is the
## literal from --gres above -- change both together.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

echo $HOSTNAME
sleep 15
echo "Test job!"


## ------------- parse info starts here ----------- ##
## This is the template every other job is copied from, so the shape matters:
## check for evidence the work actually happened, THEN for errors. A parse
## block that only greps for a failure string reports DONE for a job that
## produced no output at all -- a missing binary, a container that never
## started, a rank that died during init.

ran=$(grep -cE "^Test job!$" "$RESULT_FILE")
errors=$(grep -iE "srun: error|Segmentation fault|CANCELLED AT" "$RESULT_FILE")

if [[ -n "$RESULT_FILE" && -z "$errors" && "$ran" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi



#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.

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

## ── The two time limits ───────────────────────────────────────────────────
## Every job carries both, and they are not redundant. The reasoning is here
## rather than repeated in each one.
##
## STEP_TIMELIMIT goes to `srun --time` on the workload below and bounds the
## STEP. `#SBATCH -t` above bounds the JOB, and is deliberately the larger of
## the two -- this plus about ten minutes -- so that the step limit is what
## fires.
##
## That ordering is the whole point, because the two kills do not leave the
## same result file behind:
##
##   The job walltime      Slurm kills the batch script itself. Nothing runs
##                         after it, so no marker is written, and verdict.sh
##                         reads a result file with no end marker as
##                         INCOMPLETE -- "the job died before finishing",
##                         which is indistinguishable from a node that
##                         crashed. The node is retried on the next sweep,
##                         overruns again, and never converges.
##   The step time limit   Slurm cancels the STEP and logs
##                         `*** STEP ... CANCELLED AT ... DUE TO TIME LIMIT ***`
##                         into this file. The batch script survives, srun
##                         returns non-zero, and the parse block below writes
##                         FAIL. That is a stated verdict with the reason
##                         already in the log -- VERDICT_RUN_ERRORS in
##                         verdict.sh matches that line, so every gate reports
##                         it the same way.
##
## An overrun is usually a real finding -- a node running the same work several
## times slower than its peers -- and belongs in the log as one rather than as
## a node that mysteriously stopped.
##
## A job whose workload is not an srun step has nothing for --time to bound,
## and wraps the command in `timeout` instead -- same property (the batch script
## survives to write its marker), different mechanism. The dcgm jobs are the
## case in this tree; they write `timeout: killed after <n>`, which
## VERDICT_RUN_ERRORS matches alongside Slurm's CANCELLED AT line. Prefer
## --time where there is a step: it is Slurm's own accounting, and it does not
## depend on a signal reaching the right process.
##
## The value is twice what the AI Factory Testing Plan estimates for the test
## (the upper end, where the plan gives a range), which is the allowance for
## container start, reading a multi-gigabyte image over NFS, and a node that is
## merely slow. Where a job configures its own run duration -- stressapptest's
## RUN_SECONDS, mnubergemm's --time_to_run -- that duration is the estimate to
## double, not the plan's figure for the row. Where a job runs several steps,
## each gets its own limit and they have to sum to less than the walltime.
##
## The floor is 15 minutes. Doubling holds where the estimate is large enough
## for the overhead to scale with it; it does not for a two-minute test, where
## container start alone can exceed the whole doubled budget. Below that floor
## the doubling is not the binding constraint and a fixed allowance is.
STEP_TIMELIMIT=0:15:00

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

## The workload, in a step bounded by --time. Capture the exit status
## immediately after, before anything else runs -- srun returns non-zero when
## the step is cancelled at that limit, and that status is the only thing the
## parse block below reads.
srun --time="$STEP_TIMELIMIT" --ntasks=1 bash -c '
    echo $HOSTNAME
    sleep 15
    echo "Test job!"'
rc=$?


## ------------- parse info starts here ----------- ##
## This is the template every other job is copied from, so the shape matters,
## and the shape is: an sbatch does NOT judge its own result.
##
## It reports two things and no more -- PENDING if the workload ran, FAIL if it
## could not. Whether the output is any good is decided by the gate for this
## job in parsers/$PARSERS/verdict.sh, which is re-read on every status check
## rather than written once into this file.
##
## The difference is not stylistic. A verdict written here is frozen at run
## time: launch_job.sh skips any result that says DONE, so tightening a rule
## afterwards can never re-examine the results it was written for, and a result
## that says FAIL is never re-judged at all. Both halves of that have cost real
## time -- 25 nodes passing at 1.17 GB/s over TCP, and nvbandwidth failing every
## healthy node on a rule that matched its own matrix diagonal. Neither fix
## could reach the results it was written for.
##
## Capture the workload's exit status immediately after it, before anything
## else runs, and end the file with this line. Then write the gate:
## docs/benchmarks.md, "Adding a new benchmark", steps 4-7.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



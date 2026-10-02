#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20

## ── Allocation header ─────────────────────────────────────────────────────
## Copy the header above as-is. Steps inherit only what was EXPLICITLY
## requested, so --gres and --mem=0 are stated even though --exclusive is a
## job-level guarantee, and --cpus-per-task is deliberately absent -- it implies
## --exact. The GPU count is a literal shared with the preflight below; change
## both together. See docs/reference/jobs.md#the-allocation-header.
## --nice orders this job against everything else queued for the node: higher is
## LATER, and 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.

## Set job_name to the new benchmark's name; it appears in the status line.
# shellcheck disable=SC2034
job_name=example
## totalRuns is read out of this file's TEXT -- launch_job.sh and
## report_benchmarks.sh grep the .sbatch for it -- so keep it a plain, greppable
## one-line `totalRuns=<n>`: no export, no arithmetic, no quoting. It looks
## unused to any static check.
# shellcheck disable=SC2034
totalRuns=1

## Bounds the workload's srun step below. `#SBATCH -t` above bounds the job and
## is deliberately the larger of the two, so the step limit is what fires. Set
## this to twice the testing plan's estimate, floored at 15 minutes. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:15:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## ── Preflight ─────────────────────────────────────────────────────────────
## What the STEP holds, asked from inside a step -- the job's AllocTRES cannot
## answer that question. Copy this block unchanged except for the GPU count.
## Load-bearing: `grep -c "^GPU"` (`wc -l` counts an error message as a GPU);
## `--ntasks=1`, since the per-node form is warned about and run four times;
## SLURM_CPUS_ON_NODE rather than the physical core count, so a site reserving
## cores is not failed on every job; and the passing line's wording, which must
## avoid fail/warn/error and must not begin with a digit. See
## docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## ── Put your workload here ────────────────────────────────────────────────
## Run it as an srun step bounded by --time, and capture the exit status
## immediately after, before anything else runs -- that status is the only thing
## the parse block below reads.
srun --time="$STEP_TIMELIMIT" --ntasks=1 bash -c '
    echo $HOSTNAME
    sleep 15
    echo "Test job!"'
rc=$?


## ------------- parse info starts here ----------- ##
## Required shape: end the file with these two lines, verbatim. An sbatch does
## NOT judge its own result -- it reports PENDING if the workload ran and FAIL
## if it could not, and the gate in parsers/$PARSERS/verdict.sh decides the
## rest, re-read on every status check rather than frozen here. See
## docs/explanation/judging-benchmarks.md#where-a-pass-is-decided, then write the gate:
## docs/how-to/add-a-benchmark.md, steps 4-7.
## The `exit status:` line says WHO decided a FAIL. Keep the prefix identical
## across jobs, keep it BEFORE the marker (verdict.sh reads the last line), and
## keep the words fail/warn/error out of it.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:10:00
#SBATCH --nice=20
## nice=20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/stress-ng.txt

## No --gres: never touches a GPU. --mem=0 is not implied by --exclusive and
## `--vm-bytes 8G` needs it; no --cpus-per-task, it implies --exact and would
## shrink `--cpu 0`. See docs/reference/jobs.md#the-allocation-header.

## AI Factory Testing Plan: stress-ng -- SNT2 (Exhaustive)

# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=stress-ng

## 2x TIMEOUT; the step limit must fire before #SBATCH -t so the script lives
## to write its marker. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=2:00:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, asked from inside a step -- AllocTRES describes the
## job, not the step. Wording is fixed; verdict.sh greps it. See
## docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## ~1 hr per the plan
TIMEOUT=3600

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 --cpu-bind=none \
    stress-ng \
        --cpu 0 \
        --matrix 0 \
        --vm 4 --vm-bytes 8G \
        --cache 4 \
        --mmap 4 \
        --timeout "${TIMEOUT}" \
        --metrics-brief \
        --times
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. A FAIL with `exit status: 0` came from that gate, not from
## srun. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

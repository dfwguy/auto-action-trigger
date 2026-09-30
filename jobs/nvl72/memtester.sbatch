#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 4:10:00
#SBATCH --nice=20
## nice 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/memtester.txt

## No --gres: this job never touches a GPU. --mem=0 is load-bearing -- the test
## size below is 80% of MemAvailable. No --cpus-per-task, it implies --exact.
## See docs/reference/jobs.md#the-allocation-header.

## DRAM integrity and ECC behaviour; paired with stream.sbatch, which covers
## bandwidth. AI Factory Testing Plan SNT2 (Exhaustive).

# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=memtester

## 2x the plan's ~1-2 hr STREAM + Memtester row, upper end. The step limit
## fires first so the batch script survives to write its marker. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=4:00:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, asked from inside a step; the job's AllocTRES cannot
## answer that. Wording is fixed -- verdict.sh greps this file.
## See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Test roughly 80% of MemAvailable so the run does not trip the OOM killer.
avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
TEST_MB=$(( avail_kb * 80 / 100 / 1024 ))
LOOPS=1

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 memtester "${TEST_MB}M" "${LOOPS}"
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero status here is srun's own; a FAIL with `exit status:
## 0` came from verdict.sh, which leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

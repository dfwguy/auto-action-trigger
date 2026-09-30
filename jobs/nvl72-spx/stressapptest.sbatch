#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 4:10:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/stressapptest.txt

## No --gres, this job never touches a GPU; --mem=0 matters most here, the
## footprint below is 80% of MemAvailable. See
## docs/reference/jobs.md#the-allocation-header.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=stressapptest

## Step limit, 2x RUN_SECONDS; fires before #SBATCH -t so the batch script
## survives to write a marker. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=4:00:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds; only a step can see that. Wording is
## fixed, the parse block greps this file. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## 2-4 hr per the plan
RUN_SECONDS=7200

## Memory footprint: ~80% of MemAvailable, in MB
avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
TEST_MB=$(( avail_kb * 80 / 100 / 1024 ))

## Worker threads -- one memory copy thread per core
THREADS=$(nproc)

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 --cpu-bind=none \
    stressapptest \
        -s "${RUN_SECONDS}" \
        -M "${TEST_MB}" \
        -m "${THREADS}" \
        -W \
        -C 4
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; verdict.sh decides whether the
## result is good. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## A FAIL with a non-zero here is srun's; `exit status: 0` means verdict.sh
## failed it.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

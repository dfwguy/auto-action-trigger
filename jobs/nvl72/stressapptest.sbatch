#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 5:00:00
##SBATCH -o /home/cmods/bringup/results/%N/stressapptest.txt

## Allocation. No --gres: this job never touches a GPU. --mem=0 is load-bearing
## here above all -- the footprint below is 80% of MemAvailable on the node, and
## without it the step is capped at the partition's default memory and dies as
## soon as it allocates past it. --cpus-per-task is deliberately absent: it
## implies --exact and would cut the thread count. See docs/benchmarks.md.

## AI Factory Testing Plan: stressapptest -- SNT2/SNT3 (Exhaustive)
## Randomized memory access across all DRAM with simultaneous I/O and network
## pressure. Surfaces marginal DRAM cells, uncorrectable ECC, and
## signal-integrity faults that lighter tests miss.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=stressapptest

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
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

srun --ntasks-per-node=1 --cpu-bind=none \
    stressapptest \
        -s "${RUN_SECONDS}" \
        -M "${TEST_MB}" \
        -m "${THREADS}" \
        -W \
        -C 4


## ------------- parse info starts here ----------- ##
## stressapptest ends with "Status: PASS" or "Status: FAIL".

status=$(grep -iE "^Status: PASS" "$RESULT_FILE")
errors=$(grep -iE "hardware error|miscompare|Status: FAIL" "$RESULT_FILE")

if [[ -n "$status" && -z "$errors" ]];
then
	echo DONE
else
	echo FAIL
fi

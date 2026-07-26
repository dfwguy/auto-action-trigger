#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/memtester.txt

## Allocation. No --gres: this job never touches a GPU. --mem=0 is load-bearing
## here -- the test size below is 80% of MemAvailable on the node, and without
## it the step is capped at the partition's default memory and gets killed
## partway through, which the parse block reads as a DRAM failure.
## --cpus-per-task is deliberately absent: it implies --exact.
## See docs/benchmarks.md.

## AI Factory Testing Plan: memtester -- SNT2 (Exhaustive)
## DRAM integrity and ECC behaviour on every node. Paired with stream.sbatch
## (STREAM covers bandwidth, memtester covers integrity).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=memtester

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

## Test roughly 80% of MemAvailable so the run does not trip the OOM killer.
avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
TEST_MB=$(( avail_kb * 80 / 100 / 1024 ))
LOOPS=1

srun --ntasks-per-node=1 memtester "${TEST_MB}M" "${LOOPS}"


## ------------- parse info starts here ----------- ##
## memtester prints "<subtest> : ok" per subtest and "FAILURE" on any bad
## address, then "Done." when every loop has finished. Requiring both the
## subtest lines and the terminator means a run killed by the OOM killer or
## the walltime reports FAIL -- with only the error grep, output that stops
## partway through reads as a pass, as does a memtester that is not installed.

subtests=$(grep -cE ":[[:space:]]*ok[[:space:]]*$" "$RESULT_FILE")
done_marker=$(grep -cE "^Done\.?$" "$RESULT_FILE")
status=$(grep -iE "failure|error|srun: error" "$RESULT_FILE")

if [[ -n "$RESULT_FILE" && -z "$status" && "$subtests" -gt 0 && "$done_marker" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi

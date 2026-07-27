#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 4:10:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
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

## Step time limit, handed to srun --time below: 2x the plan's ~1-2 hr
## STREAM + Memtester row, taking the upper end.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=4:00:00

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

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 memtester "${TEST_MB}M" "${LOOPS}"
rc=$?


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

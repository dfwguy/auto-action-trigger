#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/memtester.txt

## AI Factory Testing Plan: memtester -- SNT2 (Exhaustive)
## DRAM integrity and ECC behaviour on every node. Paired with stream.sbatch
## (STREAM covers bandwidth, memtester covers integrity).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=memtester

## ------------- job info starts here ------------- ##

## Test roughly 80% of MemAvailable so the run does not trip the OOM killer.
avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
TEST_MB=$(( avail_kb * 80 / 100 / 1024 ))
LOOPS=1

srun --ntasks-per-node=1 memtester "${TEST_MB}M" "${LOOPS}"


## ------------- parse info starts here ----------- ##
## memtester prints "ok" per subtest and "FAILURE" on any bad address.

status=$(grep -iE "failure|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

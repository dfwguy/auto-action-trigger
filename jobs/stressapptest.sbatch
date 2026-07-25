#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 5:00:00
##SBATCH -o /home/cmods/bringup/results/%N/stressapptest.txt

## AI Factory Testing Plan: stressapptest -- SNT2/SNT3 (Exhaustive)
## Randomized memory access across all DRAM with simultaneous I/O and network
## pressure. Surfaces marginal DRAM cells, uncorrectable ECC, and
## signal-integrity faults that lighter tests miss.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=stressapptest

## ------------- job info starts here ------------- ##

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

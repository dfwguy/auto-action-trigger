#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 0:45:00
##SBATCH -o /home/cmods/bringup/results/%N/nvbandwidth.txt

## AI Factory Testing Plan: nvbandwidth -- SNT2 (Hybrid, TTM, Exhaustive)
## Per-GPU HBM, PCIe, and NVLink/NVSwitch bandwidth. Surfaces PCIe width/speed
## negotiation faults (x8 instead of x16) and HBM channel failures that DCGM
## does not report as explicit bandwidth numbers.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvbandwidth

## ------------- job info starts here ------------- ##

CONT=/home/cmods/bringup/containers/nvidia+nvbandwidth+26.02.sqsh

## Test cases named in the testing plan (FastTrack 7.1.1)
TESTCASES="device_to_device_memcpy_read_ce,device_to_device_bidirectional_memcpy_read_ce,host_to_device_memcpy_ce,device_to_host_memcpy_ce,device_local_copy"

unset CUDA_VISIBLE_DEVICES

srun --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                nvbandwidth -t "${TESTCASES}"

## Bare-metal alternative (no container) -- point at the local build:
#srun --ntasks-per-node=1 /home/cmods/bringup/bin/nvbandwidth -t "${TESTCASES}"


## ------------- parse info starts here ----------- ##
## nvbandwidth prints "SUM <testcase> <value>" per test case and exits non-zero
## on a waived/errored run. Require one SUM line per requested test case.

expected=$(awk -F, '{print NF}' <<< "$TESTCASES")
found=$(grep -cE "^SUM " "$RESULT_FILE")
errors=$(grep -iE "error|not supported|waived|fail" "$RESULT_FILE")

if [[ -z "$errors" && "$found" -ge "$expected" ]];
then
	echo DONE
else
	echo FAIL
fi

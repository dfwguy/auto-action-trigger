#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/nvsm.txt

## AI Factory Testing Plan: NVSM Stress Test -- SNT2 (Hybrid, Exhaustive)
## System-level compute, memory, and thermal stress across all node GPUs.
## Pre-burn-in health gate -- quarantine failing nodes before MNUberGEMM.
## Not run in the TTM variants.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvsm

## ------------- job info starts here ------------- ##

## Duration in seconds (~20 min per the plan)
STRESS_SECONDS=1200

unset CUDA_VISIBLE_DEVICES

## nvsm must run as root on the node under test
srun --ntasks-per-node=1 nvsm stress-test --force --duration="${STRESS_SECONDS}"

## Follow-on health summary for the same node
srun --ntasks-per-node=1 nvsm show health


## ------------- parse info starts here ----------- ##

status=$(grep -iE "fail|unhealthy|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

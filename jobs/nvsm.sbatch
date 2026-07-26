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

## nvsm is installed on the host alongside dcgmi -- no container. It refuses to
## run as anyone but root, and Slurm runs the task as the submitting user
## (cmods), so we escalate with sudo. `-n` keeps it non-interactive -- there is
## no tty on a batch task, so a password prompt would hang until the walltime.
## Requires a NOPASSWD sudoers grant for cmods on every compute node; see the
## nvsm section of the README.
if [[ $(id -u) -eq 0 ]]; then
	NVSM=(nvsm)
else
	NVSM=(sudo -n nvsm)
fi

## Fail fast and loudly if the grant is missing, so the parse below reports a
## setup problem instead of a bogus hardware failure.
if ! srun --ntasks-per-node=1 "${NVSM[@]}" show version > /dev/null 2>&1; then
	echo "ERROR: cannot run nvsm as root -- no passwordless sudo grant for $(id -un)"
	echo FAIL
	exit 0
fi

srun --ntasks-per-node=1 "${NVSM[@]}" stress-test --force --duration="${STRESS_SECONDS}"

## Follow-on health summary for the same node
srun --ntasks-per-node=1 "${NVSM[@]}" show health


## ------------- parse info starts here ----------- ##

status=$(grep -iE "fail|unhealthy|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

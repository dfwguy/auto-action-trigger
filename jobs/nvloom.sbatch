#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/nvloom.txt

## AI Factory Testing Plan: nvloom -- Single-Node Health + Burn-In
## SNT2/SNT3, Exhaustive only, *optional / exploratory*.
## MNNVL fabric validation per node: bandwidth uniformity across CE and SM
## engines, outlier detection, thermal behaviour under sustained collective
## load. Incubation tool -- not a required gate in any variant. See
## incubation/nvloom_MOP.md sections 4-5 in the validation-mops repo.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvloom

## ------------- job info starts here ------------- ##

CONT=/home/cmods/bringup/containers/nvloom.sqsh

export NCCL_DEBUG=WARN
export NVLOOM_MODE=health          # health | burn-in
export NVLOOM_DURATION=1800        # seconds, burn-in mode only

unset CUDA_VISIBLE_DEVICES

## Scope 1 -- single-node basic health check (nvloom MOP section 4)
srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                nvloom_cli -t single_node

## Scope 2 -- single-node burn-in (nvloom MOP section 5). Enable when the
## program has capacity to exercise the extended run.
#srun --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
#                --container-image="${CONT}" \
#                nvloom_cli -t single_node --duration "${NVLOOM_DURATION}"


## ------------- parse info starts here ----------- ##

status=$(grep -iE "fail|outlier|error" "$RESULT_FILE")

if [[ -z "$status" ]];
then
	echo DONE
else
	echo FAIL
fi

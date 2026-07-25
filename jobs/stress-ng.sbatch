#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/stress-ng.txt

## AI Factory Testing Plan: stress-ng -- SNT2 (Exhaustive)
## CPU stress across arithmetic, SIMD, cache, mmap, and OS primitives.
## Exposes thermal instability, power-delivery limits, and CPU-side faults
## before GPU-level burn-in.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=stress-ng

## ------------- job info starts here ------------- ##

## ~1 hr per the plan
TIMEOUT=3600

srun --ntasks-per-node=1 --cpu-bind=none \
    stress-ng \
        --cpu 0 \
        --matrix 0 \
        --vm 4 --vm-bytes 8G \
        --cache 4 \
        --mmap 4 \
        --timeout "${TIMEOUT}" \
        --metrics-brief \
        --times


## ------------- parse info starts here ----------- ##
## stress-ng prints "successful run completed" on a clean pass; any stressor
## failure or unexpected kill shows up as "failed" / "unsuccessful".

passed=$(grep -iE "successful run completed" "$RESULT_FILE")
failed=$(grep -iE "unsuccessful|failed|fatal" "$RESULT_FILE")

if [[ -n "$passed" && -z "$failed" ]];
then
	echo DONE
else
	echo FAIL
fi

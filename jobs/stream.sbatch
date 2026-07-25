#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/stream.txt

## AI Factory Testing Plan: STREAM -- SNT2 (Exhaustive)
## Sustained CPU memory bandwidth (Copy/Scale/Add/Triad) against arrays too
## large to fit in cache. Validates DRAM channels and NUMA configuration
## before GPU workloads. Paired with memtester.sbatch for DRAM integrity.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=stream

## ------------- job info starts here ------------- ##

STREAM_BIN=/home/cmods/bringup/bin/stream

## One OpenMP thread per core, threads pinned across all NUMA nodes
export OMP_NUM_THREADS=$(nproc)
export OMP_PROC_BIND=spread
export OMP_PLACES=cores

## Minimum acceptable Triad bandwidth in MB/s -- set per platform
TRIAD_MIN=400000

srun --ntasks-per-node=1 --cpu-bind=none "${STREAM_BIN}"


## ------------- parse info starts here ----------- ##
## STREAM prints:  Triad:   <best rate MB/s>  <avg>  <min>  <max>
## Solution validation failures print "Failed Validation".

triad=$(awk '/^Triad:/ {print $2}' "$RESULT_FILE" | head -1)
invalid=$(grep -iE "failed validation|error" "$RESULT_FILE")

if [[ -z "$invalid" && -n "$triad" ]] && awk -v t="$triad" -v m="$TRIAD_MIN" 'BEGIN{exit !(t>=m)}';
then
	echo DONE
else
	echo FAIL
fi

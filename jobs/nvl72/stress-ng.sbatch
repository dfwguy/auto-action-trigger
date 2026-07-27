#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/stress-ng.txt

## Allocation. No --gres: this job never touches a GPU. --mem=0 is stated
## because --exclusive does not imply it -- `--vm-bytes 8G` needs the memory to
## be in the allocation, not just on the node. --cpus-per-task is deliberately
## absent: it implies --exact, and `--cpu 0` means "one stressor per core the
## step can see". See docs/benchmarks.md.

## AI Factory Testing Plan: stress-ng -- SNT2 (Exhaustive)
## CPU stress across arithmetic, SIMD, cache, mmap, and OS primitives.
## Exposes thermal instability, power-delivery limits, and CPU-side faults
## before GPU-level burn-in.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=stress-ng

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

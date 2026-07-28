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
##SBATCH -o /home/cmods/bringup/results/%N/stream.txt

## Allocation. No --gres: this job never touches a GPU. --mem=0 is stated
## because --exclusive does not imply it and STREAM sizes its arrays against
## the memory it can actually get. --cpus-per-task is deliberately absent: it
## implies --exact, and the step would then see that many cores rather than the
## whole node -- which is exactly what OMP_NUM_THREADS below reads.
## See docs/benchmarks.md.

## AI Factory Testing Plan: STREAM -- SNT2 (Exhaustive)
## Sustained CPU memory bandwidth (Copy/Scale/Add/Triad) against arrays too
## large to fit in cache. Validates DRAM channels and NUMA configuration
## before GPU workloads. Paired with memtester.sbatch for DRAM integrity.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=stream

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

## STREAM ships inside the HPC-Benchmarks image, the same one the NCCL jobs use.
## stream-cpu-test.sh is Arm SBSA only (Grace/Vera); on x86 hosts install
## STREAM on the host or build it into a site image.
## Locally built image (build_containers.sh). The node-local copy that
## actions/file_copy.sh rsyncs to /tmp is preferred so job start does not read
## a multi-gigabyte image over NFS; the shared directory is the fallback for a
## node the rsync has not reached yet. See docs/containers.md.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
## Registry alternative -- every node pulls it over the network on first use.
## Note the enroot `#` separator between registry host and image path.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02

## One OpenMP thread per core, threads pinned across all NUMA nodes
OMP_NUM_THREADS=$(nproc)
export OMP_NUM_THREADS
export OMP_PROC_BIND=spread
export OMP_PLACES=cores

## The Triad floor lives in verdict.sh as VERDICT_MIN_TRIAD_MBS, not here --
## a floor applied at run time can never re-judge a result that passed an older,
## lower one. See the header of verdict.sh.

srun --time="$STEP_TIMELIMIT" --ntasks-per-node=1 --cpu-bind=none \
                --container-image="${CONT}" \
                ./stream-cpu-test.sh
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

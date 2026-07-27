#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:10:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/fio.txt

## Allocation. No --gres: this job never touches a GPU. --exclusive is what
## makes the numbers mean anything -- another job doing I/O on the same node
## would show up here as a storage fault. --mem=0 is stated because --exclusive
## does not imply it, and --cpus-per-task is deliberately absent: it implies
## --exact. See docs/benchmarks.md.

## AI Factory Testing Plan: fio -- SNT2 (Exhaustive)
## Local NVMe and shared-storage (VAST / Lustre / WekaFS) throughput, IOPS, and
## latency at multiple block sizes and queue depths. Validates storage against
## performance targets before workloads commit data.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=fio

## Per-pass step time limit, handed to srun --time below -- one limit per pass
## rather than one for the job, because that is the granularity srun --time
## works at. Four passes at 30 min sit inside the 2:10 walltime above with
## room to spare. 2x the plan's ~1 hr for fio, divided over the four passes.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker -- see example.sbatch.
PASS_TIMELIMIT=0:30:00

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

## Scratch directory on the device under test -- point at local NVMe by default.
## Change to the shared mount (e.g. /lustre, /vast) to characterize that path.
FIO_DIR=/raid/scratch/fio-$SLURM_JOB_ID
FILE_SIZE=64G
RUNTIME=120

mkdir -p "${FIO_DIR}" || exit 1

## One status for four passes: any pass failing means the job did not run to
## completion, and the loop must not let a later success overwrite an earlier
## failure. Set once here, only ever raised inside the loop.
rc=0

## Each pass is RUNTIME seconds of I/O plus laying out a FILE_SIZE file per job,
## and it is the layout that dominates on a cold filesystem -- which is what
## PASS_TIMELIMIT above is really covering.

for rw in read write randread randwrite; do
    case "$rw" in
        read|write)         bs=1M; iodepth=32 ;;
        randread|randwrite) bs=4k; iodepth=128 ;;
    esac

    echo "===== fio ${rw} bs=${bs} iodepth=${iodepth} ====="
    srun --time="$PASS_TIMELIMIT" --ntasks-per-node=1 \
        fio --name="${rw}" \
            --directory="${FIO_DIR}" \
            --rw="${rw}" \
            --bs="${bs}" \
            --iodepth="${iodepth}" \
            --numjobs=8 \
            --size="${FILE_SIZE}" \
            --runtime="${RUNTIME}" \
            --time_based \
            --direct=1 \
            --ioengine=libaio \
            --group_reporting
    pass_rc=$?
    [[ "$pass_rc" -eq 0 ]] || rc=1
done

rm -rf "${FIO_DIR}"


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## _v_gate_fio there requires one IOPS summary per pass, which is what catches
## a pass that was skipped rather than one that failed.

## The aggregate exit status over every pass -- 0 if all of them returned 0, 1
## if any did not. Written into the log rather than left only in the marker
## below: a FAIL with a non-zero here is the job's own, a FAIL with
## `exit status: 0` came from the gate in verdict.sh at status-check time.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

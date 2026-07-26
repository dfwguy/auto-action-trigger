#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:00:00
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

for rw in read write randread randwrite; do
    case "$rw" in
        read|write)         bs=1M; iodepth=32 ;;
        randread|randwrite) bs=4k; iodepth=128 ;;
    esac

    echo "===== fio ${rw} bs=${bs} iodepth=${iodepth} ====="
    srun --ntasks-per-node=1 \
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
done

rm -rf "${FIO_DIR}"


## ------------- parse info starts here ----------- ##
## Each fio pass prints a "  read: IOPS=..." / "  write: IOPS=..." summary.

runs=$(grep -cE "IOPS=" "$RESULT_FILE")
errors=$(grep -iE "fio: |error=|No such file or directory" "$RESULT_FILE")

if [[ -z "$errors" && "$runs" -ge 4 ]];
then
	echo DONE
else
	echo FAIL
fi

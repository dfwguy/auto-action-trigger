#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/fio.txt

## AI Factory Testing Plan: fio -- SNT2 (Exhaustive)
## Local NVMe and shared-storage (VAST / Lustre / WekaFS) throughput, IOPS, and
## latency at multiple block sizes and queue depths. Validates storage against
## performance targets before workloads commit data.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=fio

## ------------- job info starts here ------------- ##

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

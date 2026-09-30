#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:10:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/fio.txt

## No --gres: this job never touches a GPU. Steps inherit only what was
## explicitly requested; no --cpus-per-task, it implies --exact.
## See docs/reference/jobs.md#the-allocation-header.

## AI Factory Testing Plan: fio -- SNT2 (Exhaustive). Local NVMe and shared
## storage (VAST / Lustre / WekaFS) throughput, IOPS and latency.

## Job name is used in the status line.
# shellcheck disable=SC2034  # read by the status line, not by this script
job_name=fio

## Per-pass step limit -- srun --time bounds a step, and the four passes must
## sum inside the walltime above.
## See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
PASS_TIMELIMIT=0:30:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. The wording of
## the passing line is fixed. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Site value: the device under test. Local NVMe by default; point at the shared
## mount (e.g. /lustre, /vast) to characterize that path instead.
## See docs/how-to/enable-a-benchmark.md#check-the-dependencies-first.
FIO_DIR=/raid/scratch/fio-$SLURM_JOB_ID
FILE_SIZE=64G
RUNTIME=120

mkdir -p "${FIO_DIR}" || exit 1

## One status for four passes: only ever raised, so a later pass cannot
## overwrite an earlier failure.
rc=0

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

## Only whether the job ran is decided here; _v_gate_fio in verdict.sh decides
## whether the result is good. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## Logged, not just left in the marker: a FAIL with a non-zero here is the
## job's own, a FAIL with `exit status: 0` came from the gate.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

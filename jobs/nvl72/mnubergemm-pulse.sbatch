#!/bin/bash
##SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 6:41:00
#SBATCH --nice=100000
## Burn-in queues last; higher --nice is LATER. See
## docs/reference/jobs.md#queue-priority.

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## Job name is used in the status line.
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=mnubergemm-pulse

## Same ladder as the steady job -- only the waveform differs. See
## docs/reference/settings.md#retry-and-drain-policy.
STEP_TIMELIMIT=6:30:00

## Half of each long wave is idle, so 6 runs is the load of 3 steady ones. See
## docs/explanation/burn-in-waveform.md#two-jobs-not-one.
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
totalRuns=6


## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. Wording of the
## passing line is fixed; see docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}


## NVIDIA-internal image; version and -arch suffix must match the nodes under
## test. See docs/how-to/build-containers.md#mnubergemm. NODE_CONTAINER_DIR is the node-local
## copy rsync'd by actions/file_copy.sh.
IMG=mnubergemm-26.03-v1.17-arm.sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG

# Cluster/fabric tuning: adjust as needed for your environment
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
export NCCL_CUMEM_ENABLE=1
export NCCL_CUMEM_HOST_ENABLE=0
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=1
export NCCL_MIN_CTAS=16
export NCCL_NVLS_ENABLE=1
export UCX_TLS=tcp


## --dual_freq is Hz: 0.0013888889 is a 720 s wave, half of it a real idle.
## The workload knobs are the steady job's, unchanged, so the two compare.
## See docs/explanation/burn-in-waveform.md#the-long-wave.
srun --time="$STEP_TIMELIMIT" \
  --mpi=pmix \
  --cpu-bind=none \
  --container-image="${CONT}" \
  ./mnubergemm \
    --time_to_run 21420 \
    --workload GNC \
    --freq 400 \
    --duty 0.9 \
    --dual_mode \
    --dual_freq 0.0013888889 \
    --dual_duty 0.50 \
    --max_workload 65536 \
    --MM_max_workload 65536 \
    --MM_M 0 \
    --MM_N 0 \
    --MM_type SX_SX_SSS \
    --MM_sm_count 112 \
    --NET_sm_count=32 \
    --NET_link_order scatter_sum \
    --NET_size 20480000 \
    --CE_type H \
    --CE_size 1048576
rc=$?

## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; the verdict is derived by
## verdict.sh on every read. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## Says who decided a FAIL: non-zero is the job's own, 0 is verdict.sh's gate.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

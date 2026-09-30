#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 1:10:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/nvloom.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. --gres not --gpus-per-task, see NVIDIA_VISIBLE_DEVICES
## below. See docs/reference/jobs.md#the-allocation-header.

## MNNVL fabric validation per node -- optional / exploratory, not a required
## gate. Prerequisites (IMEX, not fabricmanager) in docs/how-to/build-containers.md#nvloom.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=nvloom

## Step limit fires before #SBATCH -t so the script survives to write its
## marker. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=1:00:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, asked from inside a step -- AllocTRES cannot answer it.
## The passing line's wording is fixed. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## NOT ENABLED BY DEFAULT -- no published image, and not in BENCHMARKS.
## Building and enabling it: docs/how-to/build-containers.md#nvloom.
IMG=nvloom-v2.0.0-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
RACK_SAMPLES=5
# shellcheck disable=SC2034  # read only by the commented-out scope 2 srun below
BURN_IN_DURATION=3600      # seconds per testcase, burn-in variant only

## Needed for the Pyxis GPU hook. Do NOT add --gpus-per-task: it causes
## CUDA_ERROR_NO_DEVICE here -- docs/how-to/build-containers.md#nvloom.
export NVIDIA_VISIBLE_DEVICES=all

## Scope 1 -- single-node basic health check (MOP section 4)
srun --time="$STEP_TIMELIMIT" \
  --container-image="${CONT}" \
  nvloom_cli \
    -s pairwise fabric-stress all-to-one multicast \
    --gpuToRackSamples ${RACK_SAMPLES}
rc=$?

## Scope 2 -- single-node burn-in (MOP section 5). `pairwise` is omitted to
## keep sustained load on fabric-stress and multicast. Raise #SBATCH -t above
## BURN_IN_DURATION before enabling.
#srun \
#  --container-image="${CONT}" \
#  nvloom_cli \
#    -s fabric-stress all-to-one multicast \
#    --duration ${BURN_IN_DURATION}


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is good is
## _v_gate_nvloom in verdict.sh. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
## Bandwidth uniformity needs the per-platform matrix and is still left to
## review of the log.

## A FAIL with a non-zero status here is the job's own; `exit status: 0` with
## FAIL came from the verdict.sh gate, which leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

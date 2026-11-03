#!/bin/bash
#SBATCH -p defq
#SBATCH -N 18
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 1:30:00
#SBATCH --nice=20
##SBATCH -o <RESULTS_DIR>/nvloom-rack-%j.txt

## Rack-level NVLink validation with NVLoom.
## Intended for single-rack / NVL72-class validation runs.
## Submit with an explicit node list for one rack, for example:
##   sbatch -w node[01-18] jobs/nvl72/nvloom-rack-nvlink.sbatch

STEP_TIMELIMIT=1:20:00
RACK_SAMPLES=${RACK_SAMPLES:-5}

# remove inherited slurm CPU/task settings from job environment
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

NVLOOM_PRECHECKS=${BRINGUP_HOME:?not set -- launch_job.sh exports it; a bare sbatch must too}/jobs/nvl72/nvloom-prechecks.sh
# shellcheck source=jobs/nvl72/nvloom-prechecks.sh
if ! source "$NVLOOM_PRECHECKS" || ! nvloom_prechecks; then
    echo FAIL
    exit 0
fi

# select the correct nvloom container image and locate it (aarch64 vs x86_64)
# Searches in NODE_CONTAINER_DIR and CONTAINER_DIR, in that order. If NODE_CONTAINER_DIR is not set,
# it will search in CONTAINER_DIR. If CONTAINER_DIR is not set, exit with an error message.
IMG=nvloom-v2.0.0-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG

export NVIDIA_VISIBLE_DEVICES=all

# A note on gpu-to-rack vs pairwise testing: gpu-to-rack is a less exhaustive version of pairwise testing. 
# Pairwise testing is more comprehensive and will test all possible combinations of GPUs in the rack. 
srun --time="$STEP_TIMELIMIT" \
  --container-image="${CONT}" \
  nvloom_cli \
    -r \
    -s gpu-to-rack egm-gpu-to-rack pairwise fabric-stress multicast all-to-one \
    --gpuToRackSamples ${RACK_SAMPLES}
rc=$?

echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL


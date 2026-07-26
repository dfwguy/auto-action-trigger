#!/bin/bash
##SBATCH -p defq
##SBATCH -N 1
#SBATCH --exclusive
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
##SBATCH --cpus-per-task=32
#SBATCH -t 6:00:00

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=mnubergemm
totalRuns=12


## ------------- job info starts here ------------- ##


## NVIDIA-internal image -- nothing to build from, it has to be obtained
## through the internal channel and imported into the containers directory.
## `./build_containers.sh -l mnubergemm` says whether it is there. The version
## and -arch suffix must match the nodes under test. See BUILD_CONTAINERS.md.
## /tmp/containers is the node-local copy rsync'd by actions/file_copy.sh.
IMG=mnubergemm-26.03-v1.17-arm.sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG

# Important for manual/hand-rolled container launches
#unset XDG_CACHE_HOME
#unset CLAUDE_CONFIG_DIR

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


srun \
  --mpi=pmix \
  --cpu-bind=none \
  --container-image="${CONT}" \
  ./mnubergemm \
    --time_to_run 21420 \
    --workload GNC \
    --freq 500 \
    --duty 1.0 \
    --MM_max_workload 65536 \
    --NET_sm_count=32 \
    --MM_M 0 \
    --MM_N 0 \
    --MM_type SX_SX_SSS \
    --MM_sm_count 112 \
    --NET_link_order scatter_sum \
    --NET_size 20480000 \
    --CE_type H \
    --CE_size 20480000
rc=$?

## ------------- parse info starts here ----------- ##
## mnubergemm is an internal tool with no documented success banner to grep
## for, so the gate is srun's own exit status plus the failure modes a burn-in
## actually dies from. That is strictly stronger than the old `grep "code 1"`,
## which was negative-only and matched neither `exit code 3` nor a rank abort.
## Add a positive output marker here once the tool's clean-run format is known.

## Without a success banner to match, `-s` is the only thing standing between
## a silent no-op and a DONE: a container that starts and exits 0 having run
## nothing produces an empty file and a zero status.

errors=$(grep -iE "srun: error|cuda error|CUDA_ERROR|assertion|assert failed|MPI_Abort|Segmentation fault|CANCELLED AT" "$RESULT_FILE")

if [[ -s "$RESULT_FILE" && "$rc" -eq 0 && -z "$errors" ]];
then
        echo DONE
else
        echo FAIL
fi


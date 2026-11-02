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

# If job is submitted with a node list spanning more than one rack, the job will fail.
# nvloom_cli checks for clusterUuid inherently and will abort if it finds a mismatch.

STEP_TIMELIMIT=1:20:00
RACK_SAMPLES=${RACK_SAMPLES:-5}

# remove inherited slurm CPU/task settings from job environment
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

# select the correct nvloom container image and locate it (aarch64 vs x86_64)
# Searches in NODE_CONTAINER_DIR and CONTAINER_DIR, in that order. If NODE_CONTAINER_DIR is not set,
# it will search in CONTAINER_DIR. If CONTAINER_DIR is not set, exit with an error message.
IMG=nvloom-v2.0.0-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG

export NVIDIA_VISIBLE_DEVICES=all

## Open MPI otherwise considers the Spectrum-X rail/VRF interfaces, whose
## addresses are not in the default namespace, and can abort MPI_Allgather
## with EADDRNOTAVAIL. Use the routable host interface for MPI coordination.
MPI_IFACE=${MPI_IFACE:-$(ip -4 route show default | awk 'NR == 1 { print $5 }')}
[[ -n "$MPI_IFACE" ]] || {
    echo "preflight: no default-route interface found for MPI coordination"
    echo FAIL
    exit 0
}
export OMPI_MCA_btl_tcp_if_include="$MPI_IFACE"
export OMPI_MCA_oob_tcp_if_include="$MPI_IFACE"
echo "MPI coordination interface: $MPI_IFACE"

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


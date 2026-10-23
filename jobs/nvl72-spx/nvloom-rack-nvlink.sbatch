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
##   sbatch -w node[01-18] jobs/nvl72-spx/nvloom-rack-nvlink.sbatch

STEP_TIMELIMIT=1:20:00
RACK_SAMPLES=${RACK_SAMPLES:-5}

unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

srun --nodes="$SLURM_NNODES" --ntasks="$SLURM_NNODES" --ntasks-per-node=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: one or more nodes did not receive the full node allocation -- see above"
    echo FAIL
    exit 0
}

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

srun --time="$STEP_TIMELIMIT" \
  --container-image="${CONT}" \
  nvloom_cli \
    -r \
    -s gpu-to-rack egm-gpu-to-rack pairwise fabric-stress multicast all-to-one \
    --gpuToRackSamples ${RACK_SAMPLES}
rc=$?

echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



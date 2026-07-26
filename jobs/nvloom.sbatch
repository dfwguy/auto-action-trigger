#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4
#SBATCH --exclusive
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/nvloom.txt

## AI Factory Testing Plan: nvloom -- Single-Node Health + Burn-In
## SNT2/SNT3, Exhaustive only, *optional / exploratory*.
## MNNVL fabric validation per node: bandwidth uniformity across CE and SM
## engines, outlier detection, thermal behaviour under sustained collective
## load. Incubation tool -- not a required gate in any variant.
##
## Follows incubation/nvloom_MOP.md sections 4 (Scope 1, basic health) and
## 5 (Scope 2, burn-in) in the validation-mops repo.
##
## Prerequisites on the node: IMEX channels present in
## /dev/nvidia-caps-imex-channels/ with the IMEX service healthy, and the
## container readable from the compute node.
##
## MOP section 2.2 also lists `systemctl status nvidia-fabricmanager` -- that
## does not apply to NVL72, where the NVLink domain is managed by NMX-C on the
## switch trays and the hosts run nvidia-imex instead. node_health.sh already
## covers the IMEX checks that matter here (imex-channels, imex-service,
## imex-readiness, imex-status).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvloom

## ------------- job info starts here ------------- ##

## NOT ENABLED BY DEFAULT -- nvloom publishes no prebuilt image, only a sample
## Dockerfile at github.com/NVIDIA/nvloom. Run `./build_containers.sh nvloom`
## on the headnode to build the image below, then add this job to the
## benchmarks= list in actions/launch_job.sh. See docs/containers.md.
## MOP reference image: /home/nvis/nvidian+nvis+nvloom+v2.0.0-arm.sqsh
IMG=nvloom-v2.0.0-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
RACK_SAMPLES=5
BURN_IN_DURATION=3600      # seconds per testcase, burn-in variant only

## Pyxis/Enroot needs this so the NVIDIA container hook bind-mounts the GPUs.
## Do NOT add --gpus-per-task -- nvloom assigns GPUs by MPI local rank, and
## scoping CUDA devices per task causes CUDA_ERROR_NO_DEVICE (MOP section 2.4).
export NVIDIA_VISIBLE_DEVICES=all

## Scope 1 -- single-node basic health check (MOP section 4)
srun \
  --container-image="${CONT}" \
  nvloom_cli \
    -s pairwise fabric-stress all-to-one multicast \
    --gpuToRackSamples ${RACK_SAMPLES}

## Scope 2 -- single-node burn-in (MOP section 5). `pairwise` is omitted to
## keep sustained load on the fabric-stress and multicast paths. Raise the
## #SBATCH -t above BURN_IN_DURATION before enabling.
#srun \
#  --container-image="${CONT}" \
#  nvloom_cli \
#    -s fabric-stress all-to-one multicast \
#    --duration ${BURN_IN_DURATION}


## ------------- parse info starts here ----------- ##
## MOP section 4 "What to Look For": no CUDA errors, assertion failures, or MPI
## aborts, and all processes enumerating the same rackGuid. Bandwidth
## uniformity (no link >3% below the matrix average, no multicast source >5%
## below peers) needs the per-platform matrix and is left to review of the log.
## Matched narrowly -- suite names like `fabric-stress` must not trip the grep.

errors=$(grep -iE "cuda error|CUDA_ERROR|assertion|assert failed|MPI_Abort|srun: error|Segmentation fault" "$RESULT_FILE")
rackguids=$(grep -oE "rackGuid[: ]+[0-9a-fA-Fx]+" "$RESULT_FILE" | awk '{print $NF}' | sort -u | wc -l)

if [[ -z "$errors" && "$rackguids" -eq 1 ]];
then
	echo DONE
else
	echo FAIL
fi

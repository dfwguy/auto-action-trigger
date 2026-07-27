#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 1:10:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/nvloom.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them. --cpus-per-task is deliberately
## absent: it implies --exact and would shrink the step. See docs/benchmarks.md.
## --gres rather than --gpus-per-task, for the reason in the NVIDIA_VISIBLE_DEVICES
## note below: scoping CUDA devices per task breaks nvloom's rank-to-GPU mapping.

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

## Step time limit, handed to srun --time below: 2x the plan's 30 min for
## the Scope 1 health check.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=1:00:00

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## NOT ENABLED BY DEFAULT -- nvloom publishes no prebuilt image, only a sample
## Dockerfile at github.com/NVIDIA/nvloom. Run `./build_containers.sh nvloom`
## on the headnode to build the image below, then add this job to the
## BENCHMARKS list in SETTINGS. See docs/containers.md.
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
srun --time="$STEP_TIMELIMIT" \
  --container-image="${CONT}" \
  nvloom_cli \
    -s pairwise fabric-stress all-to-one multicast \
    --gpuToRackSamples ${RACK_SAMPLES}
rc=$?

## Scope 2 -- single-node burn-in (MOP section 5). `pairwise` is omitted to
## keep sustained load on the fabric-stress and multicast paths. Raise the
## #SBATCH -t above BURN_IN_DURATION before enabling.
#srun \
#  --container-image="${CONT}" \
#  nvloom_cli \
#    -s fabric-stress all-to-one multicast \
#    --duration ${BURN_IN_DURATION}


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## The MOP section 4 criteria this block used to apply -- no CUDA errors,
## assertion failures or MPI aborts, and every process enumerating the same
## rackGuid -- are in _v_gate_nvloom there. Bandwidth uniformity (no link >3%
## below the matrix average, no multicast source >5% below peers) needs the
## per-platform matrix and is still left to review of the log.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

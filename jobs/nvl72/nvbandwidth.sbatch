#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 0:40:00
#SBATCH --nice=20
## 20 is the sweep's tier; higher is later. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/nvbandwidth.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## Per-GPU HBM, PCIe and NVLink/NVSwitch bandwidth -- see
## docs/how-to/build-containers.md#nvbandwidth. Adjust --gres and the preflight count
## together for the platform (4 for GB200, typically 8 for HGX H100/H200/B200).

## Job name is used in the status line.
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=nvbandwidth

## Step limit fires before #SBATCH -t so the script survives to write its
## marker. See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=0:30:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. The passing
## line's wording is fixed. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Needs an NGC login to build -- see docs/how-to/build-containers.md#nvbandwidth. The arch
## split is the CPU's, not the GPU's; NODE_CONTAINER_DIR is the node-local copy,
## the shared path the fallback. See docs/explanation/containers.md#how-the-caching-works.
IMG=nvbandwidth-v0.9-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry alternative -- needs enroot credentials on every compute node:
#case "$(uname -m)" in
#    aarch64) CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-arm ;;
#    x86_64)  CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-x86 ;;
#esac

unset CUDA_VISIBLE_DEVICES

## Full default suite (33 tests) per the MOP. For triage, list with
## `nvbandwidth -l` and add -t <test>.
srun --time="$STEP_TIMELIMIT" --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                nvbandwidth
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is any good is
## _v_gate_nvbandwidth in verdict.sh, including the MOP 6.2 criteria this block
## used to apply. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided and
## docs/explanation/judging-benchmarks.md#judge-what-the-tool-means-not-what-it-says.

## Says *who* decided a FAIL: non-zero is the workload's own, 0 is the gate.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

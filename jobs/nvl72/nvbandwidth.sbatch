#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 0:40:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/nvbandwidth.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them. --cpus-per-task is deliberately
## absent: it implies --exact and would shrink the step. See docs/benchmarks.md.

## AI Factory Testing Plan: nvbandwidth -- SNT2 (Hybrid, TTM, Exhaustive)
## Per-GPU HBM, PCIe, and NVLink/NVSwitch bandwidth. Surfaces PCIe width/speed
## negotiation faults (x8 instead of x16) and HBM channel failures that DCGM
## does not report as explicit bandwidth numbers.
##
## Follows incubation/nvbandwidth-single-node-mop.md in the validation-mops
## repo. Adjust --gres and the preflight count together for the platform (4 for
## GB200, typically 8 for HGX H100/H200/B200).

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=nvbandwidth

## Step time limit, handed to srun --time below: 2x the plan's ~15 min for
## nvbandwidth.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=0:30:00

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

## NOT ENABLED BY DEFAULT -- no public upstream image exists. Run
## `./build_containers.sh nvbandwidth` on the headnode to produce the image
## below, then add this job to the BENCHMARKS list in SETTINGS.
## See docs/containers.md.
##
## The image is architecture-specific -- that is a CPU split, not a GPU
## generation one. Grace/Vera are ARM; Intel/AMD hosts use the x86 build.
## /tmp/containers is the node-local copy rsync'd by actions/file_copy.sh;
## the shared directory is the fallback until that rsync lands.
IMG=nvbandwidth-v0.9-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
## Registry alternative -- needs enroot credentials for the private NGC org on
## every compute node:
#case "$(uname -m)" in
#    aarch64) CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-arm ;;
#    x86_64)  CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-x86 ;;
#esac

unset CUDA_VISIBLE_DEVICES

## Full default suite (33 tests) per the MOP reference command. The plan calls
## out device_to_device_memcpy_read_ce,
## device_to_device_bidirectional_memcpy_read_ce, host_to_device_memcpy_ce,
## device_to_host_memcpy_ce, and device_local_copy -- all included in the
## default suite. For triage, list with `nvbandwidth -l` and add -t <test>.
srun --time="$STEP_TIMELIMIT" --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                nvbandwidth
rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## The MOP section 6.2 criteria this block used to apply -- the N/A check, the
## coefficient-of-variation bar and the SUM count -- are in _v_gate_nvbandwidth
## there. They had to move: the N/A rule matched the matrix diagonal, so the
## job wrote FAIL on every healthy node, and a self-reported FAIL is the one
## verdict that is never re-judged. Fixing it here would have left every
## already-condemned result condemned.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

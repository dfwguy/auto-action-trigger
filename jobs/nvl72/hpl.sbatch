#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:00:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/hpl.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.
#
## Node-local copy first so job start does not read the image over NFS; the
## shared directory is the fallback. See docs/explanation/containers.md#why-local-images.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?not set -- launch_job.sh exports it; a bare sbatch must too}/$IMG
## Registry fallback; the `#` is enroot's registry/path separator.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
HPLDATPATH=${BRINGUP_HOME:?not set -- launch_job.sh exports it; a bare sbatch must too}/jobs/nvl72/hpl/

## Used in the status line.
# shellcheck disable=SC2034  # read by the status line, not by this script
job_name=hpl

## Step limit, under #SBATCH -t so the step is what Slurm cancels and the batch
## script survives to write its marker. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STEP_TIMELIMIT=1:50:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds; the job's AllocTRES cannot answer that.
## Wording is load-bearing. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

#hosts=($(scontrol show hostnames $SLURM_JOB_NODELIST))

#generate HPLDAT
#./scripts/gen_hpldat_gb200.sh ${SLURM_NNODES} > ./hpldat/hpl${SLURM_NNODES}N.dat

#sleep 2

#pdsh -R ssh -w ${hosts[0]} nvidia-imex-ctl -N

#srun --ntasks-per-node=1 ./collect-power.sh
#srun --ntasks-per-node=1 ./set-cpufreq.sh 2000000
#srun --ntasks-per-node=1 nvidia-smi -pl $i -sc 1

#srun --container-image="{CONT}" --container-mounts="${HPLDATPATH}:/hpldat" hostname
#srun --container-image="{CONT}" hostname

srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" --container-mounts="${HPLDATPATH}:/hpldat" \
                /workspace/hpl.sh \
                --dat /hpldat/hpl${SLURM_NNODES}N.dat
#                --mem-affinity 0:0:1:1 \
#                --cpu-affinity 0-35:36-71:72-107:108-143 \
#                --gpu-affinity 0:1:2:3
#		--ucx-affinity roce_r0:roce_r1:roce_r2:roce_r3
## Must stay below the commented continuations, or uncommenting one breaks it.
rc=$?

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000

## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; the `PASSED` residual gate lives in
## _v_gate_hpl in verdict.sh. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## Says who decided a FAIL: non-zero is srun's, 0 is the verdict.sh gate.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL




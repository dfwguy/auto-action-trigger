#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 2:00:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/hpl.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them. --cpus-per-task is deliberately
## absent: it implies --exact and would shrink the step. See docs/benchmarks.md.
##
## This asked for one GPU before, which is not what the job runs -- the
## commented --gpu-affinity line below maps four. Remediation-only either way:
## it is not in the BENCHMARKS list and is submitted by hand.
#
## Locally built image (build_containers.sh). The node-local copy that
## actions/file_copy.sh rsyncs to /tmp is preferred so job start does not read
## a multi-gigabyte image over NFS; the shared directory is the fallback for a
## node the rsync has not reached yet. See docs/containers.md.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
## Registry alternative -- every node pulls it over the network on first use.
## Note the enroot `#` separator between registry host and image path.
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
HPLDATPATH=/home/cmods/bringup/jobs/nvl72/hpl/

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=hpl

## Step time limit, handed to srun --time below. The plan gives no estimate for
## the remediation GEMM, so this is a bound rather than a doubling of one.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=1:50:00

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

#hosts=($(scontrol show hostnames $SLURM_JOB_NODELIST))

#generate HPLDAT
#./scripts/gen_hpldat_gb200.sh ${SLURM_NNODES} > ./hpldat/hpl${SLURM_NNODES}N.dat

#sleep 2

#ssh ${hosts[0]} nvidia-imex-ctl -N

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
## After the commented continuations, not before them: comments do not touch
## $?, and a `rc=$?` sitting between the srun and those lines would break the
## line continuation the moment somebody uncommented one.
rc=$?

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000

## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## The `PASSED` residual check this block used to apply is in _v_gate_hpl there.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL




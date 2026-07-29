#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 0:25:00
#SBATCH --nice=20
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. 20 is the sweep's tier -- behind the dcgm gates at
## 0, ahead of burn-in at 100000. See docs/benchmarks.md.
##SBATCH -o /home/cmods/bringup/results/%N/allreduce-forcesharp.txt

## Allocation. --exclusive is a JOB-level guarantee, and a step inherits only
## what was explicitly requested -- never what the job was implicitly granted.
## So --gres and --mem=0 are stated even though --exclusive is supposed to
## cover them, and --cpus-per-task is deliberately absent: it implies --exact
## and would shrink every srun below to that core count. See the allocation
## header section of docs/benchmarks.md.

## AI Factory Testing Plan: NCCL AllReduce -- Single Node, NVLink, SHARP forced.
## The same collective over the same fabric as allreduce.sbatch, with the
## NVSwitch's in-network reduction (NVLS/SHARP) made mandatory rather than
## merely permitted -- see NCCL_ALGO below. This job exists to answer "did SHARP
## run", which allreduce.sbatch cannot: a node with no NVLS support runs it
## quietly on the GPUs instead and reports a plausible number.
## Permissive counterpart: allreduce.sbatch

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=allreduce-forcesharp

## Step time limit, handed to srun --time below: 2x the plan's < 5 min for
## single-node NCCL, floored at 15 min.
## Slurm cancels the STEP at this limit, which leaves the batch script alive to
## write its marker. #SBATCH -t above is this plus a margin, so the step limit
## is what fires -- see example.sbatch.
STEP_TIMELIMIT=0:15:00
## Read out of this file's text by grep, never sourced -- see example.sbatch.
# shellcheck disable=SC2034
totalRuns=1

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
#HPLDATPATH=/home/cmods/bringup/jobs/nvl72/hpl/

export NCCL_SOCKET_IFNAME=bond0
export NCCL_DEBUG=INFO
export NCCL_P2P_LEVEL=NVL
#export NCCL_P2P_LEVEL=NVL

## NVLS is the NVSwitch's in-network reduction -- SHARP. 1 is what
## allreduce.sbatch sets and, on the 2.29 NCCL in this image, is identical to
## the shipped default of 2: allocation failure is an error, but *absent
## support* is a quiet fallback to a GPU-side algorithm. So a node with no
## working NVLS passes allreduce.sbatch at whatever a Ring run happens to
## measure, and nothing in the log says the offload never ran.
export NCCL_NVLS_ENABLE=1

## Which is why this line, and not the one above, is what makes this job
## different. Pinning the algorithm removes the fallback: NVLS is the only
## algorithm NCCL may pick, so a node that cannot use it fails in
## ncclCommInitRank instead of quietly measuring something else. That turns
## "was SHARP allowed" into "did SHARP run", which is the question being asked
## before this scales past a handful of nodes.
##
## A failure here is therefore a real answer and not a broken job -- expect the
## init error, in full, in the result file. It is also the one line to remove
## first if this job starts failing fleet-wide right after an image change:
## NCCL_ALGO is a supported knob, but which algorithms exist behind it is a
## property of the NCCL build, not of the fabric.
export NCCL_ALGO=NVLS
export NCCL_MNNVL_ENABLE=1
export NCCL_IB_DISABLE=0


## No --ntasks-per-node here on purpose: srun inherits the 4 from the #SBATCH
## header above. Setting it in both places let them drift -- the header asked
## for 4 and srun asked for 1, which Slurm resolves by warning `can't honor
## --ntasks-per-node set to 1` and running 4 anyway. One rank per GPU, so `-g 1`
## pairs with 4 tasks to cover all 4 GPUs.
srun --time="$STEP_TIMELIMIT" --mpi=pmix --export=ALL --cpu-bind=none --mem-bind=none \
                --container-image="${CONT}" \
                all_reduce_perf_mpi -b 8 -e 16G -f 2 -g 1
rc=$?
#                --dat /hpldat/hpl${SLURM_NNODES}N.dat
#                --mem-affinity 0:0:1:1 \
#                --cpu-affinity 0-35:36-71:72-107:108-143 \
#                --gpu-affinity 0:1:2:3
#		--ucx-affinity roce_r0:roce_r1:roce_r2:roce_r3

#srun --ntasks-per-node=1 nvidia-smi -pl 2500 -sc 1
#srun --ntasks-per-node=1 ./set-cpufreq.sh 3400000


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## Note that /dev/infiniband is deliberately NOT mounted for this job, unlike
## its -nonvlink counterpart. This is the NVLink scope: the collective is meant
## to stay on NVLink and never reach the network at all. Making the HCAs
## reachable would let a run that has lost NVLink quietly succeed over IB
## instead of being caught.

## The workload's exit status, written into the log rather than left only in
## the marker below. A FAIL with a non-zero here is the job's own -- srun
## returned it. A FAIL with `exit status: 0` came from the gate in verdict.sh,
## which is read at status-check time and leaves no trace in this file.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL



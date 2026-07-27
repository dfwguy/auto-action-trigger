#!/bin/bash
##SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=4
#SBATCH -t 6:41:00
#SBATCH --nice=100000
## --nice orders this job against everything else queued for the node: higher
## is LATER, 0 is the front. Burn-in sits far back so that any benchmark queued
## while it is running goes ahead of the runs still waiting -- it is the whole
## reason burn-in no longer has to be gated behind a clean sweep. It does not
## preempt: --exclusive means the run already on the node keeps it. The value is
## deliberately large because on priority/basic a nice only outranks jobs within
## that many job ids. See docs/benchmarks.md.

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them.
##
## --cpus-per-task stays out. It is the one option here that is both
## load-bearing and dangerous: setting it implies --exact, so the srun below
## silently drops to that core count instead of the whole node -- a burn-in
## running on a quarter of the cores that still reports a clean pass. If it is
## ever needed (ntasks-per-node x cpus-per-task should equal the node's core
## count, or cores are stranded inside an exclusive allocation), re-state it on
## the srun or export SRUN_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK}" alongside it.
## See docs/benchmarks.md.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=mnubergemm

## Step time limit, handed to srun --time below. The workload itself is capped
## by --time_to_run 21420 further down -- 5h57m -- so this is that plus half an
## hour, not the 2x it used to be. A step limit at twice the workload cannot
## catch a hung run: it waits six hours past the point the job was supposed to
## be finished before admitting anything is wrong, and MAX_JOB_HOURS then has
## to be set high enough to clear the padding rather than the work.
##
## Four limits in a ladder, each above the one before, and they have to move
## together. Change --time_to_run and all four move:
##
##   --time_to_run 21420   5:57  the workload's own cap -- what normally ends it
##   STEP_TIMELIMIT        6:30  srun kills the step; the script still writes
##   #SBATCH -t            6:41  slurm kills the job, marker or not
##   MAX_JOB_HOURS            7  the sequencer drains the node for timeout
##
## Slurm cancels the STEP at STEP_TIMELIMIT, which leaves the batch script
## alive to write its marker; #SBATCH -t above is that plus a margin so the
## step limit is what fires -- see example.sbatch. MAX_JOB_HOURS is in
## SETTINGS, and is the one that is not in this file: set it below the job
## limit and the sequencer drains healthy nodes running on schedule.
STEP_TIMELIMIT=6:30:00

## 12 runs of ~6h, submitted one at a time, so a full burn-in holds the node
## for about three days -- the plan's 24-72 hour row. Each run is its own job
## and its own result file, so an interrupted burn-in resumes at the run it got
## to rather than starting over.
totalRuns=12


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


## NVIDIA-internal image -- nothing to build from, it has to be obtained
## through the internal channel and imported into the containers directory.
## `./build_containers.sh -l mnubergemm` says whether it is there. The version
## and -arch suffix must match the nodes under test. See docs/containers.md.
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


srun --time="$STEP_TIMELIMIT" \
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

## Only whether the job ran is decided here. Whether the result is any good is
## decided by verdict.sh, which is read on every status check rather than
## written once into this file. That is what lets a tightened gate re-judge
## results that already exist -- see the header of verdict.sh.
##
## mnubergemm has no documented success banner, so _v_gate_mnubergemm there has
## no positive marker to require beyond a non-empty file -- a container that
## starts, runs nothing and exits 0 produces an empty file and a zero status.
## Add a real marker there once the tool's clean-run format is known.
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL


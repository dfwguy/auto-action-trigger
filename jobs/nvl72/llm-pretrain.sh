#!/bin/bash
#
# Single-tray LLM pre-training, launched from the compute node rather than
# submitted as a batch script. `llmb-run` builds and submits its own Slurm job,
# so this file's whole purpose is to hand it the node, the job name and the
# result path the sequencer expects, and to fail loudly if it cannot.
#
# Set up by ./build_llmb.sh on the head node, once per CPU architecture. This
# script never reaches a registry or the internet: see docs/llmb.md.

## Read by actions/launch_job.sh with grep, not by running this file. Without
## the job_launch line the file is taken for a sourced helper -- like
## nccl-hca.sh in this directory -- and is never launched.
# shellcheck disable=SC2034  # read from outside; exporting would change every job's environment
job_launch=host
# shellcheck disable=SC2034  # ditto -- the status line reads this out of the file
job_name=llm-pretrain

## ------------- what the sequencer handed us ------------- ##

## RESULT_FILE is where the verdict is read from, and SBATCH_JOB_NAME is what
## this node's queue gates match on. Both come from launch_job.sh; a hand-run
## has to supply them.
## No apostrophes in a :? message: bash parses it as a quote even inside "".
: "${RESULT_FILE:?RESULT_FILE is not set -- run this through actions/launch_job.sh, or set it by hand}"
: "${SBATCH_JOB_NAME:?SBATCH_JOB_NAME is not set -- the submitted job would be invisible to the gates on this node}"

## Refusals are written where the report reads, not just to stdout: this script
## returns before the work starts, so a silent refusal is a node that simply
## stops testing. See docs/llmb.md#when-the-launch-is-refused.
refuse() {
    printf '%s\n' "llm-pretrain: $1" "exit status: 1" FAIL > "$RESULT_FILE"
    echo "llm-pretrain: $1" >&2
    exit 1
}

## ------------- the recipe ------------- ##

## Llama 3.1 8B rather than Nemotron-H 56B: 56B has a minimum scale of 32 GPUs,
## which is eight trays, and this is a per-node gate. 8B is the smallest
## pre-training recipe in the collection.
WORKLOAD=pretrain_llama3.1
MODEL_SIZE=8b
DTYPE=fp8
## Four GPUs is the tray. Below the recipe's characterised floor of 8, so
## --force is required -- see docs/llmb.md#running-below-the-characterised-scale
## for why that is sound here and what it costs.
SCALE=4

## ------------- the install ------------- ##

export LLMB_INSTALL="${LLMB_INSTALL:?LLMB_INSTALL is not set -- settings.sh derives it; see docs/llmb.md}"

[[ -d "$LLMB_INSTALL" ]] ||
    refuse "no install at $LLMB_INSTALL -- run ./build_llmb.sh on the head node"

command -v llmb-run >/dev/null 2>&1 ||
    refuse "llmb-run is not on PATH -- see docs/llmb.md#what-build_llmb.sh-leaves-behind"

## Llama is a GATED Hugging Face repo, so unlike synthetic-data workloads this
## one needs a real tokenizer cache. Compute nodes have no route off the
## cluster: without these three, a cache miss is a silent stall that eats the
## wall limit and reports as a training failure.
## See docs/llmb.md#running-offline.
export HF_HOME="$LLMB_INSTALL/hf"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

[[ -d "$HF_HOME" ]] ||
    refuse "no pre-staged $HF_HOME -- the node cannot download it; re-run ./build_llmb.sh -d on the head node"

cd "$LLMB_INSTALL" || refuse "cannot cd to $LLMB_INSTALL"

## ------------- launch ------------- ##

## llmb-run submits a SECOND Slurm job for post-processing unless this is set.
## That job carries neither of this node's two job names, so the foreign-job
## gate in launch_job.sh would read it as somebody else's work and leave the
## node alone every cycle for as long as it existed.
## See docs/llmb.md#the-post-processing-job.
export LLMB_SKIP_PP=1

## --nodelist, --nice and --slurm-arg are llmb-run's own flags, and they are how
## the three things an .sbatch would get from `sbatch -w -J --output` reach the
## submission. --slurm-arg takes KEY=VALUE with no leading dashes, and refuses
## the keys that have dedicated flags (nodelist, exclude, reservation, segment,
## nice). --nice 20 is the sweep's tier, matching every .sbatch in this
## directory. See docs/llmb.md#pinning-the-submission.
##
## Returns as soon as the job is queued. Anything that blocks here holds the
## BCM action open for the length of the training run.
out=$(llmb-run submit \
        -w "$WORKLOAD" \
        -s "$MODEL_SIZE" \
        --dtype "$DTYPE" \
        --scale "$SCALE" \
        --force \
        --nodelist "$HOSTNAME" \
        --nice 20 \
        --slurm-arg "job-name=$SBATCH_JOB_NAME" \
        --slurm-arg "output=$RESULT_FILE" 2>&1)
rc=$?

echo "$out"

## launch_job.sh confirms the queue itself, so this only has to report. A
## non-zero status with nothing queued is diagnosed there, against squeue.
[[ "$rc" -eq 0 ]] || refuse "llmb-run exited $rc: ${out:-<no output>}"

#!/bin/bash
#
# Single-tray LLM pre-training, launched from the compute node rather than
# submitted as a batch script. `llmb-run` builds and submits its own Slurm job,
# so this file's whole purpose is to hand it the node, the job name and the
# result path the sequencer expects, and to fail loudly if it cannot.
#
# Set up by ./build_llmb.sh on the head node, once per CPU architecture. This
# script never reaches a registry or the internet: see docs/explanation/llmb.md.

## Without job_launch the file reads as a sourced helper and is never launched.
## See docs/explanation/sequencing.md#host-launched-jobs.
# shellcheck disable=SC2034  # both read from outside, by grep
job_launch=host
# shellcheck disable=SC2034
job_name=llm-pretrain

## ------------- what the sequencer handed us ------------- ##

## Both come from launch_job.sh; a hand-run has to supply them.
## No apostrophes in a :? message: bash parses it as a quote even inside "".
: "${RESULT_FILE:?RESULT_FILE is not set -- run this through actions/launch_job.sh, or set it by hand}"
: "${SBATCH_JOB_NAME:?SBATCH_JOB_NAME is not set -- the submitted job would be invisible to the gates on this node}"

## Written where the report reads, not just to stderr.
## See docs/explanation/llmb.md#when-the-launch-is-refused.
refuse() {
    printf '%s\n' "llm-pretrain: $1" "exit status: 1" FAIL > "$RESULT_FILE"
    echo "llm-pretrain: $1" >&2
    exit 1
}

## ------------- the recipe ------------- ##

## 8B, and SCALE below the recipe's characterised floor of 8, both explained in
## docs/explanation/llmb.md#running-below-the-characterised-scale.
WORKLOAD=pretrain_llama3.1
MODEL_SIZE=8b
DTYPE=fp8
SCALE=4

## ------------- the install ------------- ##

export LLMB_INSTALL="${LLMB_INSTALL:?LLMB_INSTALL is not set -- settings.sh derives it; see docs/explanation/llmb.md}"

[[ -d "$LLMB_INSTALL" ]] ||
    refuse "no install at $LLMB_INSTALL -- run ./build_llmb.sh on the head node"

## An adopted install keeps llmb-run in a venv that is on nobody's PATH.
## See docs/explanation/llmb.md#where-llmb-run-actually-lives.
[[ -n "${LLMB_BIN:-}" ]] && export PATH="$LLMB_BIN:$PATH"

command -v llmb-run >/dev/null 2>&1 ||
    refuse "llmb-run is not on PATH and LLMB_BIN=${LLMB_BIN:-<unset>} does not hold it -- see docs/how-to/enable-llm-pretrain.md#1-install-on-the-head-node"

## A cache miss on a node with no route out must fail, not stall.
## See docs/explanation/llmb.md#running-offline.
export HF_HOME="${LLMB_HF:-$LLMB_INSTALL/hf}"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

[[ -d "$HF_HOME" ]] ||
    refuse "no pre-staged $HF_HOME -- the node cannot download it; re-run ./build_llmb.sh -d on the head node, or set LLMB_HF if the cache is elsewhere"

cd "$LLMB_INSTALL" || refuse "cannot cd to $LLMB_INSTALL"

## ------------- launch ------------- ##

## Without this, llmb-run submits a second job that trips the foreign-job gate
## on every cycle. See docs/explanation/llmb.md#the-post-processing-job.
export LLMB_SKIP_PP=1

## What an .sbatch would get from `sbatch -w -J --output`, in llmb-run's flags.
## See docs/explanation/llmb.md#pinning-the-submission.
##
## Must return once queued: anything blocking here holds the BCM action open for
## the length of the training run.
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

## launch_job.sh confirms against squeue; this only has to report.
[[ "$rc" -eq 0 ]] || refuse "llmb-run exited $rc: ${out:-<no output>}"

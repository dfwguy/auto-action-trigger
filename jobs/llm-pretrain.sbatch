#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH -t 2:00:00
##SBATCH -o /home/cmods/bringup/results/%N/llm-pretrain.txt

## AI Factory Testing Plan: Single-Node LLM Pre-Training -- SNT3
## End-to-end pre-training scoped to one node. Validates the full workload
## stack: framework, containers, data pipeline, checkpointing, and intra-node
## collectives. Primary workload gate in TTM Single Node; node-level workload
## check in Hybrid before multi-node NCCL.
##
## Recipe is still TBD -- see incubation/TTM_Single_Node_Workload_MOP.md in the
## validation-mops repo. FastTrack variant uses pretrain_nemotron-h at minimum
## supported scale via llmb-run; candidates are Llama 3.1 8B (Megatron-Bridge,
## 8 GPUs, FP8/NVFP4) with Qwen3 30B (BF16) as the ungated fallback.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=llm-pretrain

## ------------- job info starts here ------------- ##

## llmb-run installation root (llmb_install from the LLMB installer)
export LLMB_INSTALL=/home/cmods/bringup/llmb
export LLMB_WORKLOAD=pretrain_nemotron-h
export LLMB_MODEL_SIZE=56b
export LLMB_DTYPE=fp8
export LLMB_SCALE=8          # GPUs on the single node under test

## Site-specific Slurm/container settings consumed by llmb-run
export SBATCH_PARTITION="${SLURM_JOB_PARTITION}"
#export SBATCH_ACCOUNT=
#export HF_TOKEN=

cd "${LLMB_INSTALL}" || exit 1

srun --ntasks-per-node=1 --export=ALL \
    llmb-run single \
        -w "${LLMB_WORKLOAD}" \
        -s "${LLMB_MODEL_SIZE}" \
        --dtype "${LLMB_DTYPE}" \
        --scale "${LLMB_SCALE}"


## ------------- parse info starts here ----------- ##
## A healthy run reports per-step timings and no CUDA/NCCL aborts.

timings=$(grep -icE "train_step_timing|reduced_train_loss" "$RESULT_FILE")
errors=$(grep -iE "traceback|cuda error|nccl error|out of memory|srun: error" "$RESULT_FILE")

if [[ -z "$errors" && "$timings" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi

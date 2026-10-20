# Enable the DeepSeek-V3 proxy job

The job needs one NeMo image and one offline Hugging Face cache, following
the same pattern as [the LLM pre-training jobs](enable-llm-pretrain.md).
It runs a reduced DeepSeek-V3 recipe on one four-GPU GB300 ARM node using
synthetic data. No LLMB installation or model weights are needed at runtime.

## 1. Stage the NeMo image

The frozen recipe requires exactly `nvidia+nemo+26.04.01-arm.sqsh`.
Confirm `NEMO_TAG=26.04.01` in the site's settings, then run on the head node:

```bash
./build_containers.sh -a arm nemo
./build_containers.sh -l
```

The image lands in `CONTAINER_DIR`; `actions/file_copy.sh` copies it into
`NODE_CONTAINER_DIR` on each node. The job checks the node-local directory
first, then the shared directory. Other tags, unsuffixed images and modified
NCCL variants are not accepted. See [build-containers.md#nemo](build-containers.md#nemo).

## 2. Stage the DeepSeek cache

Compute nodes run offline. Put the compute-node path to a readable cache in
`SETTINGS`, for example:

```bash
LLM_HF_HOME=/cluster/bringup/llm/hf
```

Reuse an existing DeepSeek cache if available. Otherwise, stage only
`config.json` from the revision below on a networked host. Run as the cache
owner, using the staging host's view of the configured cache path:

```bash
(
    set -eu
    umask 022
    LLM_HF_HOME=/cluster/bringup/llm/hf
    revision=e815299b0bcbac849fa540c768ef21845365c9eb
    model_cache="$LLM_HF_HOME/hub/models--deepseek-ai--DeepSeek-V3"
    mkdir -p "$model_cache/snapshots/$revision" "$model_cache/refs"
    curl -fL --retry 2 --max-time 60 \
      "https://huggingface.co/deepseek-ai/DeepSeek-V3/resolve/$revision/config.json" \
      -o "$model_cache/snapshots/$revision/config.json"
    python3 -m json.tool "$model_cache/snapshots/$revision/config.json" >/dev/null
    printf '%s\n' "$revision" > "$model_cache/refs/main"
)
```

Keep the directories traversable and files readable by `JOB_USER`. If head
and compute nodes mount the share at different paths, stage through the head
node's path and put the compute-node path in `SETTINGS`.

The cache is mounted at `/hf-cache` inside the container, with all three
offline flags set. Experiment files stay in the writable container's
`/mnt/nemo`; stdout in the result file is the evidence used by the parser.

## 3. Run one node

Use `JOBS=nvl72` with `PARSERS=nvl72`, or `JOBS=nvl72-spx` with
`PARSERS=spectrum-x`. Confirm that the node has four GB300 GPUs and that
GPUs 0–1 use CPU NUMA node 0 and GPUs 2–3 use node 1.

After deploying the candidate, run as `JOB_USER` on one idle compute node:

1. Run `actions/launch_job.sh --test deepseek-v3-proxy --explain` and inspect
   the printed submission and cache/image paths.
2. Drop `--explain` to submit the job on that node.
3. Read `RESULTS_DIR/<node>/trigger.log` and
   `RESULTS_DIR/<node>/deepseek-v3-proxy.txt`.
4. Confirm all 50 iterations completed and Slurm reports `COMPLETED` with
   exit code `0:0`.

Check the trial result with the configured parser from the deployment root,
replacing `<node>` with the tested hostname:

```bash
source ./settings.sh
source "$PARSERS_DIR/verdict.sh"
verdict deepseek-v3-proxy "$RESULTS_DIR/<node>/deepseek-v3-proxy.txt"
printf '%s %s\n' "$VERDICT_STATUS" "$VERDICT_REASON"
```

See [run-a-job-by-hand.md](run-a-job-by-hand.md) for clush/pdsh commands and
[update-the-deployment.md](update-the-deployment.md) for installation.
The allocation limit is 50 minutes and the training step limit is 40 minutes.
`PENDING` at the end of the log means execution finished; the parser derives
`DONE` from at least 50 timing records and no recognized runtime errors.

## 4. Set the timing ceiling and enable the job

`VERDICT_MAX_STEP_MS_DEEPSEEK_V3_PROXY=0` disables the performance ceiling.
Collect healthy runs on multiple nodes before setting a median step-time
limit. See [reference/settings.md](../reference/settings.md#llm-step-time-ceilings).

Once the launcher path and results are validated, add `deepseek-v3-proxy` to
`BENCHMARKS`. Each invocation uses one node; this does not test inter-node
communication. Revalidate the frozen recipe when changing the image or hardware.

## If a launch is refused

Check the result file for the reason: incomplete allocation, unsupported CPU
architecture, missing pinned image, unset or empty `LLM_HF_HOME`, or a missing
runner inside the image. A missing DeepSeek configuration is a cache-staging
failure; repair the cache on the networked host and retry offline.

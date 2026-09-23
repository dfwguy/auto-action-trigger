# Enable the LLM pre-training jobs

The two jobs need one NeMo image and one offline Hugging Face cache. They do
not need an LLMB installation at runtime. Why the jobs have different shapes is
[explanation/llmb.md](../explanation/llmb.md).

## 1. Stage the NeMo image

Run this on the head node, once per CPU architecture. `nvl72` is ARM:

```bash
./build_containers.sh -a arm nemo
./build_containers.sh -l
```

The image lands in `CONTAINER_DIR`; `actions/file_copy.sh` copies it into
`NODE_CONTAINER_DIR` on each node. The NGC credentials are the ones
`./build_containers.sh -L` writes. No registry credential reaches a compute
node. See [build-containers.md#nemo](build-containers.md#nemo).

An image imported by an old LLMB installation works too:

```bash
cp "$LLMB_INSTALL"/images/nvidia+nemo+*.sqsh "$CONTAINER_DIR"/
```

Keep the upstream filename: its version ties the measurement to the frozen
recipe.

## 2. Stage the Llama cache

Llama is a **gated** Hugging Face repository. It requires access approval for
the account behind `HF_TOKEN`; approval is per account rather than carried by
the token. Compute nodes run offline, so `LLM_HF_HOME` is required and must name
a non-empty directory they can read.

Put its compute-node path in `SETTINGS`:

```bash
LLM_HF_HOME=/cluster/bringup/llm/hf
```

Do not put an access token in `SETTINGS`. A token is needed only while staging
the cache on a networked head node and never reaches a compute node.

### Run now from an existing LLMB cache

Find the known-good cache that the old installation populated:

```bash
./build_llmb.sh -l
```

The report prints `LLMB_HF=<resolved-path>`. Copy that directory once into the
new standalone location; do not use `--delete` while establishing it:

```bash
mkdir -p /cluster/bringup/llm/hf
rsync -a <resolved-LLMB_HF>/ /cluster/bringup/llm/hf/
test -n "$(find /cluster/bringup/llm/hf -mindepth 1 -maxdepth 1 -print -quit)"
```

For the first smoke test, `LLM_HF_HOME` may point directly at the resolved
`LLMB_HF` directory. That proves the new job path before copying data, but the
old install directory remains a storage dependency until the cache is copied
and the setting is changed to the standalone path.

If the head and compute nodes mount the share at different paths, use the head
node's path as the `rsync` destination and put the compute-node view in
`SETTINGS`. The job validates the path from the compute node immediately before
starting the container.

This is the shortest supported migration path because it preserves the exact
cache layout already proven by the recipe. Once copied, neither job reads
`LLMB_INSTALL`, `LLMB_HF`, the LLMB virtual environment, its config, or its
workload tree.

The cache can later be populated directly with
`huggingface_hub.snapshot_download()`. Do that only after recording the exact
repository and file patterns used by the pinned Llama recipe: downloading the
whole model repository needlessly stages weights, while an incomplete pattern
fails only after the job reaches tokenizer setup.

### What the jobs see

The host directory in `LLM_HF_HOME` is mounted at `/hf-cache` inside the
container. Both jobs set `HF_HOME=/hf-cache` and all three offline flags. Their
generated NeMo files go under the writable container's `/mnt/nemo` and are
intentionally ephemeral; the evidence used by the verdict is stdout in
`results/<node>/llm-pretrain*.txt`.

## 3. Run one node

In order, because each step is checkable on its own:

1. Stage the image and set a populated `LLM_HF_HOME` as above.
2. Run `actions/launch_job.sh --test llm-pretrain --explain` and confirm the
   image, `CONTAINER_DIR` and `LLM_HF_HOME` in the printed submission.
3. Drop `--explain` on that one node and read `results/<node>/trigger.log` and
   `results/<node>/llm-pretrain.txt`.
4. Run `actions/launch_job.sh --test llm-pretrain-solo` on the same node and
   read `results/<node>/llm-pretrain-solo.txt`.
5. Check both outputs with `./tests/verdict-test.sh`, then add the jobs to
   `BENCHMARKS`.

The job's four ranks and the tray's GPU count have to agree; both are set for
`nvl72` in `jobs/nvl72/llm-pretrain.sbatch`. On a platform with a different GPU
count, both move together, as does the NUMA divisor described in
[explanation/llmb.md#the-numa-binding](../explanation/llmb.md#the-numa-binding).

## 4. Check the solo training command

`jobs/nvl72/llm-pretrain-solo.sbatch` carries a command captured from a real
scale-1 submission. It is the sibling's `run_script.py` invocation with
`--num_gpus 1`.

`--dry-run` will **not** provide a replacement. It prints the task list but not
the generated script; capture the generated artifacts as described in
[capture-an-sbatch-from-llmb-run.md](capture-an-sbatch-from-llmb-run.md).

Any replacement must remain a **single-process** invocation: no `torchrun`,
inner `srun`, or distributed launcher. The four copies are already four Slurm
tasks. Keep the per-rank `CUDA_VISIBLE_DEVICES`, the
`WORLD_SIZE=1 RANK=0 LOCAL_RANK=0` overrides, the private rendezvous port and
`srun --label`. See
[explanation/llmb.md#keeping-the-four-solo-copies-independent](../explanation/llmb.md#keeping-the-four-solo-copies-independent).

## 5. Set the spread floor

`VERDICT_MAX_COV_LLM_SOLO` ships as **0.02**, four times the `0.005` a healthy
GB300 tray showed. Check it against the second and third trays: a healthy tray
near the line means widen it, not that the tray is bad. `0` skips the check. See
[explanation/llmb.md#judging-the-four-step-times](../explanation/llmb.md#judging-the-four-step-times).

## If a launch is refused

Every refusal writes `FAIL` and its reason into the result file. The reasons,
in order, are: the step did not receive the whole node; no `nvidia+nemo` image
was found; `LLM_HF_HOME` was unset, missing or empty; or
`/opt/Megatron-Bridge/scripts/performance/run_script.py` was absent from the
image.

Anything absent from the cache at launch is a staging failure, not a slow GPU.
Repair the standalone cache on the head node; the compute node remains offline.

## LLMB after migration

`build_llmb.sh`, `llmb_check.py` and `llmb-run` remain useful for capturing a
new upstream recipe. They are not production runtime dependencies. A site can
remove its LLMB installation after the image and known-good cache have been
copied and both jobs have passed using `LLM_HF_HOME`.

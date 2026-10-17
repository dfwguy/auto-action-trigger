# Run the four-GPU DeepSeek-V3 proxy

This is the existing LLM job pattern adapted to DeepSeek-V3's reduced FP8-MX
training recipe. Start with one GB300 ARM node and the existing NeMo image.
No LLMB installation is needed at runtime. The model uses synthetic data;
full model weights are not required.

## Check the existing environment

Use the site's settings to locate the image and offline cache. The batch file
selects exactly `nvidia+nemo+26.04.01-arm.sqsh`, first from
`NODE_CONTAINER_DIR`, then `CONTAINER_DIR`. Modified NCCL images are excluded.
A non-empty `LLM_HF_HOME` is the same prerequisite used by `llm-pretrain`.
Do not assume that it contains DeepSeek assets: first inspect the installed
container and try the recipe offline. Stage only files an actual error shows
are missing. Never download full model weights for this proxy.

Confirm the node's availability and topology:

```bash
scontrol show node "$NC_NODE"
squeue -w "$NC_NODE"
clush -w "$NC_NODE" 'uname -m; nvidia-smi -L; nvidia-smi topo -m'
pdsh -R ssh -w "$NC_NODE" 'uname -m; nvidia-smi -L; nvidia-smi topo -m'
```

Use either fan-out tool. The job expects four GB300 GPUs, with ranks 0–1
bound to CPU NUMA node 0 and ranks 2–3 to node 1. Verify rank/GPU assignment
inside the allocation before interpreting performance.

## Validate a standalone copy first

Transfer the candidate batch file to the head node as
`$HOME/deepseek-v3-proxy.sbatch`. Use an account with a Slurm association and
read access to the image/cache. For this standalone trial, write logs into
that account's own directory rather than the automation account's results.
Set `CONTAINER_DIR`, `NODE_CONTAINER_DIR` and `LLM_HF_HOME` to the site's
compute-node paths; these are example NC values:

```bash
mkdir -p "$HOME/deepseek-validation"
sbatch -p defq -w "$NC_NODE" -J deepseek-v3-proxy-smoke \
  --export=ALL,CONTAINER_DIR=/opt/containers,NODE_CONTAINER_DIR=/opt/containers,LLM_HF_HOME=/home/cmods/bringup-data/llm/hf \
  --output="$HOME/deepseek-validation/%x-%j.out" \
  "$HOME/deepseek-v3-proxy.sbatch"
```

This reserves one exclusive node for up to 50 minutes. The training step has
a 40-minute limit so the script can report failure before the allocation ends.
Check the returned job ID with `squeue -j <job-id>` and inspect the log when it
finishes. Preserve the log, job ID, candidate revision and image identity.

`PENDING` at the end of the result is an execution marker, not Slurm queue
state. The parser requires at least 50 timing records and no recognized
runtime errors before deriving `DONE`. Its separate timing ceiling defaults
to zero; functional success is not performance acceptance.

## Integrate after validation

Keep `deepseek-v3-proxy` out of `BENCHMARKS` during initial trials. The job is
provided for `JOBS=nvl72` with `PARSERS=nvl72`, and `JOBS=nvl72-spx` with
`PARSERS=spectrum-x`. Both run the same single-node payload; neither certifies
inter-node network performance.

Once the candidate is deployed through
[the deployment procedure](update-the-deployment.md), run as `JOB_USER` with
`launch_job.sh --test deepseek-v3-proxy --explain`, then `--verbose`, through
clush or pdsh. See [manual jobs](run-a-job-by-hand.md).
Repeat on the same node and healthy peers before setting
`VERDICT_MAX_STEP_MS_DEEPSEEK_V3_PROXY` or enabling fleet coverage.

The payload follows Exemplar v26.06.01: NeMo 26.04.01, FP8-MX, TP=1, PP=1,
VP disabled, EP=4, hidden size 1024, 24 layers, micro-batch 4 and 50 steps.
Re-derive it when the container or recipe version changes. The success fixture
is trimmed from NC job 207418; error mutations remain synthetic except the
captured missing-config failure from job 207416.

## Captured NC initialization failure

Job 207416 reached the container runner on a four-GPU GB300 node but failed
before training. `AutoBridge.from_hf_pretrained("deepseek-ai/DeepSeek-V3")`
requested the model configuration with `load_weights=False`. The mounted
cache contained Llama assets and no DeepSeek entry, and offline mode correctly
prevented a download from compute nodes. The rank-0 traceback is captured in
`tests/fixtures/deepseek-v3-proxy__missing-config.txt`.

Stage the missing configuration in the same Hugging Face cache layout on a
networked staging host, record its repository revision, and repeat the job
without changing the workload. This failure does not establish GPU or fabric
health. The 256-GPU base config printed before the exception is not evidence
of the effective proxy configuration; verify applied overrides after startup.

## First NC functional validation

Job **207418** ran on `sys1-gso1-p-phy-gpu1-su27` using the existing
`nvidia+nemo+26.04.01-arm.sqsh` image. It completed 50 unique iterations,
reported zero skipped and NaN iterations, and ended with `exit status: 0`
and `PENDING`. Both supported parsers derive `DONE` from the full log.
The effective configuration confirms TP=1, PP=1, EP=4, 24 layers, hidden
size 1024, micro-batch 4, global batch 64 and sequence length 4096, using
mock data and MXFP8. The initial 256-GPU config print is the base template,
not the effective proxy's parallelism.

The median across 50 iterations is **4336.95 ms**. Iterations 35–44 average
**4444.74 ms**, ranging from 4261.8 to 5072.7 ms. These are observations from
one run, not a shipped timing ceiling or an official Exemplar performance
comparison. User-provided `sacct` output confirms the allocation and all
steps (`batch`, `extern`, `.0`, `.1`) are `COMPLETED` with exit code `0:0`.
The allocation lasted **00:07:00** with 144 CPUs, four GPUs and one node;
the training container step (`.1`) lasted **00:06:57**.

Before this run, the networked NC head node staged only DeepSeek-V3's
1660-byte `config.json`, revision `e815299b0bcbac849fa540c768ef21845365c9eb`,
into the shared Hugging Face cache. The compute node had no external network
route and training remained offline. No model weights or additional runtime
packages were installed for this run.

`tests/fixtures/deepseek-v3-proxy__good.txt` retains the first 400 log lines
and the dataset/training tail. Only the large intervening parameter listing
is omitted, and trailing whitespace is stripped. Keep the full original log
with the validation evidence.

## Second NC node validation

User-provided output for job **207419** on
`sys1-gso1-p-phy-gpu126-su21` reports `exit status: 0` followed by `PENDING`.
Slurm accounting confirms the allocation and all steps are `COMPLETED` with
exit code `0:0`: total elapsed **00:07:02**, training container step (`.1`)
**00:07:00**. Pre-run inspection showed an idle ARM node with 144 CPUs,
four GB300 GPUs, NV18 between all GPU pairs, the expected CPU affinities and
the pinned image path present.

The complete second log confirms 50 unique iterations (1–50), zero skipped
and NaN iterations, and `DONE` from both supported parsers with the timing
ceiling disabled. The execution line identifies the expected node and image;
the recipe and mock-data settings match the first run.

| Job | Median iteration (ms) | Iterations 35–44 mean (ms) | Slurm elapsed |
|---|---:|---:|---|
| 207418 | 4336.95 | 4444.74 | 00:07:00 |
| 207419 | 4339.05 | 4468.68 | 00:07:02 |

The median differs by approximately **0.048%**. These two observations support
functional repeatability across nodes; they do not establish a performance
ceiling or certify inter-node communication. Image digests and repeated runs
on the same node remain to be collected.

# The two LLM jobs, and why they are shaped that way

The tree runs one LLM, **Llama 3.1 8B FP8**, in two deliberately different
shapes:

| | `llm-pretrain` | `llm-pretrain-solo` |
|---|---|---|
| Launch | host-launched `.sh` via `llmb-run submit` | ordinary `.sbatch` |
| Shape | one run, 4-way data parallel across the tray | 4 independent copies, one GPU each |
| Exercises | framework, container, data pipeline **and the gradient all-reduce**, together | per-device compute only — no collectives at all |
| Answers | is this node able to train | *which GPU* on it is slow |
| Gate | training stepped at all | four ranks stepped, and they agree with each other |

They are not two settings of one job. Installing and enabling them is
[how-to/enable-llm-pretrain.md](../how-to/enable-llm-pretrain.md); the tool
itself is [reference/llmb-run.md](../reference/llmb-run.md).

## Why not Nemotron-H

The obvious pick is wrong. `pretrain_nemotron-h` ships at **56B only**, and its
minimum scale is **32 GPUs** — eight trays. It is a cluster benchmark, not a
per-node gate, and nothing about it fits here.

Llama 3.1 8B is the smallest pre-training recipe in the collection, and the only
one that a 4-GPU tray can hold.

## Running below the characterised scale

Llama 3.1 8B is characterised at **8–128 GPUs**. A tray is 4, so both jobs pass
`--force`, which bypasses `llmb-run`'s scale validation.

That is sound here rather than a hack, and the recipe table is why. On GB200 at
FP8 the 8B configuration is:

| TP | PP | CP | FSDP | DP | MBS | GBS | GA |
|----|----|----|------|----|-----|-----|-----|
| 1 | 1 | 1 | False | GPUs | 2 | GPUs×16 | 8 |

**Pure data parallel.** Every rank holds a complete replica of the model and its
optimizer state; nothing is sharded across ranks, so there is no parallelism
plan to violate by using fewer of them. Every derived quantity is a function of
the GPU count — `GBS = MBS × GA × DP = 2 × 8 × GPUs`, exactly the `GPUs×16` in
the table — and that identity holds at 4 and at 1 just as it does at 8.

8B replicated per GPU is roughly 128 GB of Adam state against a GB200's ~186 GB.
It fits, which is why the recipe shards nothing in the first place.

**What it costs.** Numbers from a forced 4-GPU run are *not* comparable to
NVIDIA's published 8-GPU figures: different global batch size, uncharacterised
configuration. For a bringup gate that is the right trade — the question is
whether node 3 matches node 40 and the fleet median, not whether either matches
a spec sheet. Every other floor is an observed band off this hardware for the
same reason.

**Do not quote these numbers as Llama 3.1 8B benchmark results.**

## Why `llm-pretrain` is not an `.sbatch`

`llm-pretrain` is the only job in the tree that does not run as a batch script.
`llmb-run` builds and submits its own Slurm job, so the framework cannot treat
it as a payload — it hands it the node, the job name and the result path, and
gets out of the way. How the sequencer treats a `.sh` job is
[sequencing.md#host-launched-jobs](sequencing.md#host-launched-jobs).

The framework's model is one `sbatch` per node: `actions/launch_job.sh` submits
with `-w <node> -J bringup-<node> --output=results/<node>/<job>.txt`, the body
`srun`s something inside that allocation, and `parsers/*/verdict.sh` reads the
output file.

`llmb-run` is a submitter, not a payload. Running it under `srun` inside an
exclusive whole-node allocation means the job it submits needs the node the
outer job is already holding, so it queues behind itself until the outer wall
limit fires. The result file gets a submission message rather than training
output, and the gate fails a run that never started.

Running it *without* Slurm is worse, and is the thing to not do: a training run
started as a host process is invisible to `squeue`, so the next cycle sees an
idle node and submits another benchmark onto the same four GPUs. Both die, and
`DRAIN_AFTER_FAILED_BENCHMARK` drains the node for what was a scheduling
mistake. The `MAX_JOB_HOURS` reaper cannot see it either.

So the job stays in Slurm and `llmb-run` does the submitting.

## Where the install lives

`LLMB_INSTALL`, shipped as `/home/cmods/llmb` — deliberately *outside*
`BRINGUP_HOME`. It holds a venv, a multi-GB image, a tokenizer and a dataset,
and `bringup/` is a tree a tarball drop replaces. `build_llmb.sh` refuses to
install into `BRINGUP_HOME` or below it rather than letting an upgrade delete a
day of staging.

An empty `LLMB_INSTALL` means "no llmb install" and is a real answer: a site not
running `llm-pretrain` needs none of this.

## Pinning the collection

`LLMB_REF` is the git tag `build_llmb.sh` checks out after cloning
`dgxc-benchmarking`. It ships as `v26.06.01`.

It is a tag rather than `main` so that re-running `build_llmb.sh` reinstalls the
same thing. The install is one shared directory on NFS, so every node is always
running whatever is in it — the risk is not that two nodes disagree today, it is
that a reinstall three months from now quietly swaps the recipe underneath a
floor in `verdict.sh` that was set against the old one. Results either side of
that would not be comparable, and nothing would say so.

## Pinning the submission

`llmb-run` has native flags for everything an `.sbatch` would get from
`sbatch -w -J --output`, so nothing has to be guessed:

| What | Flag |
|---|---|
| Pin to this node | `--nodelist "$HOSTNAME"` |
| Sweep priority tier | `--nice 20` |
| Job name the gates match | `--slurm-arg "job-name=$SBATCH_JOB_NAME"` |
| Where the result lands | `--slurm-arg "output=$RESULT_FILE"` |

`--slurm-arg` takes `KEY=VALUE` with **no leading dashes** and is repeatable. It
refuses the keys that have dedicated flags — `nodelist`, `exclude`,
`reservation`, `segment`, `nice` — so those must use their own flag. `job-name`
and `output` are not on that list, which is what makes this work.

`launch_job.sh` does not take the launcher's word for it. After running a `.sh`
job it asks `squeue` whether a job named `bringup-<node>` actually appeared, and
traces `SUBMIT FAILED` naming the launcher and its exit status if not.

### The post-processing job

`llmb-run` submits a **second** Slurm job for post-processing. Both jobs set
`LLMB_SKIP_PP=1` to stop it.

That job would carry neither of this node's two job names, so the foreign-job
gate in `launch_job.sh` would read it as somebody else's work and leave the node
alone — every cycle, for as long as it existed. The node would go quiet with a
correct-looking trace line, which is the exact failure mode the trace design is
meant to prevent.

## Running offline

Both LLM jobs export `HF_HOME=$LLMB_INSTALL/hf`, `HF_HUB_OFFLINE=1`,
`HF_DATASETS_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`.

This matters for Llama specifically. Llama is a **gated** Hugging Face repo, so
it needs a real tokenizer cache and an access approval on the account behind
`HF_TOKEN` — approval is per-account and is not carried by the token. (Had we
gone with Nemotron-H, none of this would apply: it trains on synthetic data and
stages nothing.)

Those three are not tidiness. Without them a cache miss on a node with no route
out is a silent stall that eats the two-hour wall limit and is then reported as
a training failure — a hardware verdict for a staging mistake. With them the
same miss fails immediately and says what was missing.

The corollary: anything absent from `$LLMB_INSTALL/hf` at launch is a failed
run, not a slow one.

## When the launch is refused

Every refusal in `llm-pretrain.sh` writes `FAIL` and its reason into
`RESULT_FILE` before exiting, rather than only to stderr.

The script returns before the training starts, so there is no later chance to
explain itself. A refusal that only went to stderr would leave no result file,
which the sweep reads as "not run yet" and retries every cycle forever — a node
that has quietly stopped testing. See
[architecture.md#silence-is-the-enemy](architecture.md#silence-is-the-enemy).

The refusals, in order: no `RESULT_FILE` or `SBATCH_JOB_NAME` (run by hand
rather than through the sequencer), no install at `$LLMB_INSTALL`, no `llmb-run`
on `PATH`, and no pre-staged `$HF_HOME`.

## Keeping the four solo copies independent

Two things in `llm-pretrain-solo.sbatch` do this, and both are load-bearing:

- `--gpus-per-task=1` gives each task its own `CUDA_VISIBLE_DEVICES`, so rank N
  sees GPU N and nothing else.
- `WORLD_SIZE=1 RANK=0 LOCAL_RANK=0` inside the step. NeMo reads the `SLURM_*`
  rank variables and would otherwise form one four-way distributed group across
  the tasks — which is `llm-pretrain`, not this job, and would report a single
  step time instead of four. The failure is quiet: the run succeeds and the gate
  sees one rank reporting, which reads as three dead GPUs.

`srun --label` prefixes each line with its task id. That prefix is the only
thing tying a step time to a GPU, and `verdict.sh` parses it — do not remove it.

## Judging the four step times

`_v_gate_llm_pretrain_solo` in `parsers/nvl72/verdict.sh` asks two questions the
single-model gate cannot.

**Did all four report?** Ranks are counted *distinct*, not as a line count. One
rank printing forty timings while three print none is exactly the failure this
job exists to find, and `_v_require_count` would pass it. `VERDICT_DETAIL` names
which ranks did report.

**Do they agree?** Per-rank *median* step time, then the coefficient of
variation across the four medians — the same measure `_v_nvb_unstable` uses.
Median rather than mean because the first steps of a run are warmup and are
legitimately slower on every GPU; one slow step must not read as one slow
device. The reason string is identical on every node failing this way, so
`dshbak` keeps them in one block, while the detail names the offending GPU:

```
per-GPU step times disagree -- spread above 0.05
cov 0.074, slowest gpu 2 at 0.4740s vs 0.4202s mean
```

`VERDICT_MAX_COV_LLM_SOLO` ships as **0**, which skips the spread check — the
house convention for a floor with no established band, and honest here: no node
has run this job, so any number would be invented. A made-up floor either drains
the fleet on day one or never fires. Set it from what a healthy node actually
shows.

Because 0 makes the spread check silent, `tests/verdict-test.sh` sets a band
explicitly and asserts the outlier is caught *and named* — otherwise shipping 0
and shipping a broken check would look identical in the suite. The three
`llm-pretrain-solo__*` fixtures are synthetic for the same reason; replace them
with real captures once a node has run it.

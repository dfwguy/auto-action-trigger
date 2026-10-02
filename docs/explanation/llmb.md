# The two LLM jobs, and why they are shaped that way

The tree runs one LLM, **Llama 3.1 8B FP8**, in two deliberately different
shapes:

| | `llm-pretrain` | `llm-pretrain-solo` |
|---|---|---|
| Launch | ordinary `.sbatch`, frozen from an `llmb-run` capture | ordinary `.sbatch` |
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

It fits, which is why the recipe shards nothing in the first place. Measured on
a GB300 tray at four GPUs, from the run's own report: weight and optimizer
**68.9 GB** theoretical, **59.9 GB** allocated, **193.8 GB** reserved. The
reserved figure is the one that decides whether a scale fits, and it is most of
the device — which is why nothing smaller than this recipe has room to spare.

**What it costs.** Numbers from a forced 4-GPU run are *not* comparable to
NVIDIA's published 8-GPU figures: different global batch size, uncharacterised
configuration. For a bringup gate that is the right trade — the question is
whether node 3 matches node 40 and the fleet median, not whether either matches
a spec sheet. Every other floor is an observed band off this hardware for the
same reason.

**Do not quote these numbers as Llama 3.1 8B benchmark results.**

## Why `llm-pretrain` is not an `.sbatch`

**Superseded.** `llm-pretrain` is now `jobs/$JOBS/llm-pretrain.sbatch`, frozen
from a captured submission — [The frozen recipe](#the-frozen-recipe) below. This
section records why the host-launched form existed, because the constraint it
describes is still true of `llmb-run` and is the reason the tree stopped calling
it.

`llm-pretrain` was the only job in the tree that did not run as a batch script.
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

That left submission with `llmb-run` as a temporary compromise. Freezing the
generated batch script removed the nested-submitter problem and restored the
ordinary one-`sbatch`-per-node model.

## Where the install lives

`LLMB_INSTALL`, shipped as `/home/cmods/llmb`, is the capture tool's workspace
and is deliberately outside `BRINGUP_HOME`. It can hold a venv, image, cache and
dataset, while `bringup/` is a tree a tarball drop replaces. `build_llmb.sh`
refuses to install into `BRINGUP_HOME` or below it rather than letting an
upgrade delete a day of staging.

An empty `LLMB_INSTALL` means "no local capture tool" and is a real answer. The
frozen LLM jobs can still run from their image and `LLM_HF_HOME`.

## The installer's enroot import

The collection's `install.sh` downloads its container image by shelling out to
`enroot import`. On a headnode with no `/etc/enroot/enroot.conf` that fails
before it transfers anything:

```
mkdir: cannot create directory ‘/var/lib/enroot’: Permission denied
mkdir: cannot create directory ‘/run/enroot’: Permission denied
Error: Failed to download .../nvidia+nemo+26.04.01.sqsh
```

`enroot` creates `ENROOT_DATA_PATH` and `ENROOT_RUNTIME_PATH` at startup for
every subcommand, `import` included, and their compiled defaults —
`/var/lib/enroot` and `/run/enroot` — are root-only. The compute nodes get
writable values from `/etc/enroot/enroot.conf`; the headnode does not. So
`build_llmb.sh` exports all four enroot paths under `/tmp/*/$UID` before running
the installer, exactly as `build_containers.sh` does for the same reason —
[containers.md#how-the-caching-works](containers.md#how-the-caching-works) has
the cache side of it, which is why `ENROOT_CACHE_PATH` and `ENROOT_TEMP_PATH`
come along: their defaults sit under `$HOME`, which is NFS here, and an import
otherwise writes a multi-gigabyte layer tree over the wire and reads it back.

The installer's own advice — "try a SLURM-based installation" — is not the fix,
and **neither is `sudo`**. A root install produces root-owned capture artifacts
that the automation account cannot copy or inspect. Setting the four variables
is the whole of it.

## Adopting an existing install

A cluster often already has an llmb-run install that somebody else built, and
re-installing 300 GB beside it to get a layout this tree recognises is the wrong
answer. So `LLMB_INSTALL` no longer implies a layout. Four settings name the
pieces, and an empty one is *searched for* rather than assumed:

| Setting | Searched, in order |
|---|---|
| `LLMB_BIN` | `$LLMB_INSTALL/llmb-run`, `llmb_venv/bin/`, `venvs/*/bin/`, `bin/`, the same `llmb_venv/bin/` *beside* the root, then `PATH` |
| `LLMB_CONFIG` | `$LLMB_INSTALL/cluster_config.yaml`, beside the root, then the copy in `src/cli/llmb-run/` |
| `LLMB_IMAGES` | `$LLMB_INSTALL/images` |
| `LLMB_HF` | `$LLMB_INSTALL/hf`, `environment.HF_HOME` from the config, then `hf/` beside the root |

`build_llmb.sh -l` runs the search and prints what answered, then exits non-zero
if the capture installation is incomplete.

The report ends by printing the assignments it resolved by fallback. In
particular, `LLMB_HF` identifies the known-good cache to copy once into the
standalone `LLM_HF_HOME`; none of the four capture settings is passed to jobs.

Three failures this exists to catch, none of which look like failures:

- **The `bin/` trap.** An installer-built root has a `bin/`, and it holds `uv`,
  not `llmb-run`. Resolution looks for the *executable*, never a directory to
  put on `PATH`.
- **The CLI lives outside the install.** `llmb_venv/` is frequently a sibling of
  `LLMB_INSTALL`, so `llmb-run` is not under the root at all and is on no
  node's `PATH`. `LLMB_BIN` is what `build_llmb.sh -l` resolves and what a
  capture run needs on the head node; no job reads it any more.
- **The HF cache is somewhere else.** `LLMB_HF` identifies the source cache for
  migration. The running jobs mount the independent `LLM_HF_HOME` at the fixed
  in-container path `/hf-cache`.

### Telling a real config from the template

`src/cli/llmb-run/cluster_config.yaml` in the collection is an **example**, and
it parses as a valid schema-2 config: `llmb_install: "/lustre/path/to/LLMB_INSTALL"`,
`HF_TOKEN: "hf_token"`, one workload named `pretraining_nemotron`. Read as
configuration it describes a cluster that does not exist, and every check
downstream passes against it.

`llmb_check.py` treats those placeholder markers as a rejection rather than a
config. The related check is `config points at`: an install that was copied or
moved keeps the absolute paths of the tree it was built in, and the failure
otherwise lands at submit time on a compute node.

### Where `llmb-run` actually lives

Two installs on one head node, both real, neither the same shape:

```
/home/cmods/llmb/          src/  images/  llmb_venv/
workspace/llmb/            cluster_config.yaml  images/  llmb_repo/  venvs/  bin/
workspace/llmb_venv/       <- the CLI for the install above, beside it
```

`src/` against `llmb_repo/` is the difference between a git checkout of the
collection and the recipe copy its installer makes; both carry `release.yaml`,
and only the first answers `git describe`.

### Reading the config without PyYAML

A head node's system `python3` has no `yaml` module — the collection's own
Python lives in a venv this tree must not depend on. `llmb_check.py` parses the
mapping-and-list subset the config is written in, which is all the installer
ever emits. `tests/llmb-check-test.sh` holds it against a copy of the real file.

The alternative was `grep`, and it does not survive `slurm.gpu.partition` and
`workloads.config.<workload>.venv_path` living at two different depths under
keys whose names repeat.

## Pinning the collection

`LLMB_REF` is the git tag `build_llmb.sh` checks out after cloning
`dgxc-benchmarking`. It ships as `v26.06.01`.

It is also the **version gate**. `build_llmb.sh -l` asks the install what it is
— `git describe` in a checkout, else `llmb_version` from `release.yaml` — and
fails when the answer is not `LLMB_REF`, naming which source it read. A leading
`v` on one side only is the same version; `26.06.00` against `v26.06.01` is not.

An adopted install is routinely at some other version, and the setting is where
that is recorded: change `LLMB_REF` to what the install actually is, having
re-read the floors below. Empty skips the gate entirely, the same convention as
`VERDICT_MAX_COV_LLM_SOLO=0`. What is not acceptable is silence, because the
floors in `verdict.sh` were set against one recipe and nothing else would say so.

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

`llmb-run` submits a **second** Slurm job for post-processing. `LLMB_SKIP_PP=1`
stops it, and a capture run must set it.

That job would carry neither of this node's two job names, so the foreign-job
gate in `launch_job.sh` would read it as somebody else's work and leave the node
alone — every cycle, for as long as it existed. The node would go quiet with a
correct-looking trace line, which is the exact failure mode the trace design is
meant to prevent.

## Running offline

Both LLM jobs require the site setting `LLM_HF_HOME`, mount that host directory
at `/hf-cache`, and export `HF_HOME=/hf-cache`, `HF_HUB_OFFLINE=1`,
`HF_DATASETS_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` inside the container.

This matters for Llama specifically. Llama is a **gated** Hugging Face repo, so
it needs a real tokenizer cache and an access approval on the account behind
`HF_TOKEN` — approval is per-account and is not carried by the token. (Had we
gone with Nemotron-H, none of this would apply: it trains on synthetic data and
stages nothing.)

Those three are not tidiness. Without them a cache miss on a node with no route
out is a silent stall that eats the two-hour wall limit and is then reported as
a training failure — a hardware verdict for a staging mistake. With them the
same miss fails immediately and says what was missing.

The corollary: anything absent from `LLM_HF_HOME` at launch is a failed run, not
a slow one. The job checks that the directory exists and is non-empty before it
starts the container.

## The frozen recipe

`llmb-run` is a generator, and generators drift. The tree needs one comparable
number per node across a bringup that runs for weeks, and a submitter that
rebuilds its job from installed recipe metadata on every call cannot promise
that: a reinstall, a `--config_variant` fallback, or a recipe version bump
changes the job without changing anything in this repo. The first captured run
showed all three risks at once — `gpu_type` resolved to `gb300`, the v2
configuration for it did not exist and silently fell back to v1, and the install
reported a version that was not `LLMB_REF`.

So the recipe is captured once and checked in. `jobs/$JOBS/llm-pretrain.sbatch`
holds the allocation shape, the container, the mounts, the environment and the
training command that a real submission produced, and nothing on the node calls
`llmb-run`. Re-deriving it when the collection moves is
[how-to/capture-an-sbatch-from-llmb-run.md](../how-to/capture-an-sbatch-from-llmb-run.md).

The runtime no longer reads the install. The jobs run
`/opt/Megatron-Bridge/scripts/performance/run_script.py` from the image, mount
only `LLM_HF_HOME`, and write NeMo's generated files into the writable
container under `/mnt/nemo`. Those files are ephemeral; Slurm already captures
the training output the verdict reads. The image reaches nodes through
`CONTAINER_DIR` and `file_copy.sh` like every other image.

LLMB remains a capture-time tool. It is useful when an upstream recipe version
must be regenerated and reviewed, but the resulting jobs need only the image
and standalone cache. The known-good migration path is to copy the cache
reported as `LLMB_HF` by `build_llmb.sh -l` into `LLM_HF_HOME`; see
[how-to/enable-llm-pretrain.md#run-now-from-an-existing-llmb-cache](../how-to/enable-llm-pretrain.md#run-now-from-an-existing-llmb-cache).

### The captured environment

Eight variables come out of the generated script unchanged, and they are not
tidiness — they are the recipe's performance configuration:

| Variable | What it does |
|---|---|
| `CUDA_DEVICE_MAX_CONNECTIONS=32` | Set by the recipe's perf plugin; not the CUDA default |
| `NCCL_NVLS_ENABLE=0` | NVLink SHARP off for this recipe |
| `NVTE_FWD_LAYERNORM_SM_MARGIN=16`, `NVTE_BWD_LAYERNORM_SM_MARGIN=16` | SM reserved for communication overlap |
| `TORCH_NCCL_AVOID_RECORD_STREAMS=1`, `TORCH_NCCL_HIGH_PRIORITY=1` | NCCL stream behaviour |
| `TOKENIZERS_PARALLELISM=False` | Silences a fork warning that otherwise floods the result file |
| `PYTHONUNBUFFERED=1` | Without it the step timings arrive in blocks and a killed run looks like a run that never stepped |

The three offline flags are separate and are
[Running offline](#running-offline) above. That the generated script sets them
independently is a confirmation of that reasoning, not a coincidence.

### Two step-timing formats

The gates look for step timings, and which string a healthy run prints is a
property of the training framework in the image, not of the job or the node:

| Framework | Prints |
|---|---|
| Megatron-Bridge | `iteration 12/50 | … elapsed time per iteration (ms): 862.5 | lm loss: …` |
| NeMo | `train_step_timing in s: 0.4010`, `reduced_train_loss` |

This is not a detail. The gates originally knew only the NeMo strings, and the
captured runs — both of them, at scale 4 and scale 1 — printed **zero** of them
and fifty of the other. A healthy 50-step run would have been reported as `no
training step timings`, which reads as a node that failed to train: a hardware
verdict for a string mismatch, on every node, silently.

`VERDICT_STEP_TIMING` in `parsers/$PARSERS/verdict.sh` holds both, and the solo
spread check parses whichever appeared. Seconds against milliseconds does not
matter there — a coefficient of variation is a ratio, so the unit cancels, and
one run never mixes the two.

The general form of this: a gate keyed on an upstream log string is a dependency
on that string, and nothing upstream promises to keep it. When a recipe version
changes, re-reading the log for the strings the gate wants is part of the
capture — [how-to/capture-an-sbatch-from-llmb-run.md](../how-to/capture-an-sbatch-from-llmb-run.md).

### The NUMA binding

```
numactl --cpunodebind=$((SLURM_LOCALID/2)) --membind=$((SLURM_LOCALID/2))
```

Four local ranks across two NUMA nodes, pinning each rank's memory to the node
its GPU hangs off. It is captured verbatim because it is part of the measured
configuration, and it is the line to revisit first on any tray that is not a
4-GPU GB200/GB300 — the divisor is the tray layout, written as arithmetic.

## When the launch is refused

Every refusal in both LLM jobs prints its reason and `FAIL` into the result file
and exits **zero**, rather than dying with a status and no output.

A refusal that only went to stderr would leave a result file the sweep reads as
"not run yet", and it would retry every cycle forever — a node that has quietly
stopped testing. See
[architecture.md#silence-is-the-enemy](architecture.md#silence-is-the-enemy).

The refusals in `llm-pretrain.sbatch`, in order: the step did not receive the
whole node, no `nvidia+nemo` image in `$NODE_CONTAINER_DIR` or `$CONTAINER_DIR`, no
non-empty `LLM_HF_HOME`, and no `run_script.py` at
`/opt/Megatron-Bridge/scripts/performance` in that image —
[The frozen recipe](#the-frozen-recipe).

## Keeping the four solo copies independent

Two things in `llm-pretrain-solo.sbatch` do this, and both are load-bearing:

- `MASTER_ADDR=127.0.0.1` and `MASTER_PORT=29500+$SLURM_LOCALID`. Each copy is
  its own one-process distributed group and still needs a rendezvous, and four
  of them on one node default to the same port: three die with
  `EADDRINUSE ... address already in use` while the fourth trains, which reads
  as three failed GPUs. A private port per rank is the whole fix.
- `CUDA_VISIBLE_DEVICES=$SLURM_LOCALID`, set inside the step, so rank N uses GPU
  N and nothing else. **Slurm's own GPU-binding flags do not work here**, and
  they fail in a way that reads like a hardware fault: `--gpus-per-task=1` and
  then `--gres=gpu:4 --gpu-bind=single:1` each delivered exactly one device to
  the step, with the *winning rank varying between runs* — rank 0 on one
  attempt, rank 1 on the next. The three ranks that got nothing die at
  `Megatron requires CUDA`, which mentions no GPUs at all.

  The sibling job is the evidence for the fix: `llm-pretrain` gives all four
  ranks a device and its `srun` names no GPU flags whatsoever, inheriting the
  job's `--gres=gpu:4` so every task sees all four. Adding step-level GPU flags
  is what breaks it, so this job asks for nothing and does the pinning itself.
- `WORLD_SIZE=1 RANK=0 LOCAL_RANK=0` inside the step. NeMo reads the `SLURM_*`
  rank variables and would otherwise form one four-way distributed group across
  the tasks — which is `llm-pretrain`, not this job, and would report a single
  step time instead of four. The failure is quiet: the run succeeds and the gate
  sees one rank reporting, which reads as three dead GPUs.

`srun --label` prefixes each line with its task id. That prefix is the only
thing tying a step time to a GPU, and `verdict.sh` parses it — do not remove it.

## Why the solo job turns CUDA graphs off

At `--num_gpus 1` there is no data-parallel group, so the distributed optimizer
has nothing to shard its state across and each copy carries the whole thing.
Measured on a GB300, from the two runs' own reports:

| | `llm-pretrain` (4 GPUs) | `llm-pretrain-solo` (1 GPU) |
|---|---|---|
| weight + optimizer, theoretical | 68.9 GB | **137.9 GB** |
| allocated | 59.9 GB | **156.3 GB** |
| CUDA graph private pools | — | 131.3 GB |
| in use, against 276.5 GB | — | **276.0 GB** |

The first attempt died at iteration 4, immediately after `CUDA graph capture
done`, failing to allocate 448 MiB. 156 GB of weights and optimizer fits on the
device with room to spare; 156 plus 131 GB of full-iteration graph pools does
not. `--cuda_graph_impl none` is the whole fix, and it is the cheapest of the
levers the recipe exposes — the others (`--recompute_num_layers`,
`--activation_offload_layers`, `--use_megatron_fsdp`) cost step time, or in
FSDP's case do nothing at all when there is one rank.

**The two jobs are therefore not measured under the same execution mode**, and
that is accepted rather than tolerated. `llm-pretrain` asks whether the node can
train; `llm-pretrain-solo` asks which of its four GPUs is slow, and answers it
by comparing the four against each other in the same run. Neither question needs
the two jobs' step times to be comparable, and making them comparable would
mean giving up either the graphs on the four-way run or the job's ability to run
at all. Do not "fix" this by aligning them.

## Judging the step time

The spread check below asks whether a tray's four GPUs agree with each other. It
cannot see a tray where all four are slow together — agreement hides that
perfectly. So both jobs also carry an absolute ceiling on the **median**
iteration, `VERDICT_MAX_STEP_MS_LLM_PRETRAIN` and `VERDICT_MAX_STEP_MS_LLM_SOLO`.

Median, not mean, and for a reason visible in every run: iteration 1 costs
12.2 s to initialise and iteration 4 costs 5.8 s to capture CUDA graphs, against
a steady state of 3.3 s. A mean over 50 iterations carries roughly 0.3 s of
warmup that has nothing to do with the hardware; the median does not notice it.

That median is also what `report_benchmarks.sh` prints in both LLM columns, under the
label `step_ms`, and it comes from the same `_v_llm_step_ms` the gate calls
rather than from a second copy of the arithmetic. So the report's
`min`/`median`/`mean`/`max` for `llm-pretrain` and `llm-pretrain-solo` read
against `VERDICT_MAX_STEP_MS_LLM_PRETRAIN` and `VERDICT_MAX_STEP_MS_LLM_SOLO`
directly, and the distance between the fleet's median and the ceiling is what
says whether a band wants tightening. A run that printed fewer than five
iterations has no median and prints its status word instead of a number; what
stops that from being a free pass is [A run that stopped
early](#a-run-that-stopped-early) below.

Read that summary block with one correction: `report_benchmarks.sh` prints a number
for a `FAIL` cell as well as a `DONE` one, so the `min`/`median`/`mean`/`max`
pool both. Re-deriving a band from it means filtering to `DONE` first, or the
sample includes the nodes the band rejected.

The solo column carries the step time and not the spread, because a cell holds
one figure and the step time is the one the two jobs share. A tray failing on
spread alone says so in its `FAIL` reason, with the offending GPU named.

The shipped numbers are **estimates at +5%** of one healthy tray — 3310 ms at
four GPUs, 3341 ms per solo copy. That is deliberately loose: the job of a
starting band is to catch a node that is plainly slow while a real floor is
being assembled from several trays. A tray that trips it at 5% is worth looking
at before assuming the number is wrong, and a fleet where nothing ever trips it
should be tightened rather than trusted.

## A run that stopped early

A ceiling on the median asks whether the steps were fast. It does not ask
whether there were any, and the gap between those two questions was a hole big
enough to pass a broken node.

`_v_llm_step_ms` needs five timings before it will report a median, and returned
nothing below that. `_v_llm_step_median` reads that nothing as "no band to apply
here" and returns success, which is right when the ceiling is unset and wrong
when the run simply died. So a run that printed four iterations and stopped —
without emitting any of the `VERDICT_RUN_ERRORS` strings — cleared every check
the four-way gate had, and reported `DONE`.

Worse, the failure got *less* visible the further the run got. Iterations 1 and
4 are warmup and are several times the steady-state cost, so a run that stopped
at four has a median dragged upwards and would likely have tripped the ceiling
anyway. One that stopped at twenty has a median indistinguishable from a healthy
node's, because the twenty iterations it did manage really were healthy. The
node then reads as a pass on the strength of the part of the run that worked.

`VERDICT_MIN_LLM_ITERATIONS` closes it, and ships as **50** — the whole run. The
recipe trains a fixed 50 iterations, so anything less is a run that stopped, and
a run that stopped is a failed node rather than a fast one. There is no band of
"enough to judge" between the two worth defending: the wall limit firing, a rank
dying quietly and a container exiting mid-run all land in the same place, and
all of them are findings.

The two jobs count it differently, and the unit is worth knowing before moving
the number:

| Job | What is counted | Where |
|---|---|---|
| `llm-pretrain` | timing lines in the file | `_v_require_count`, after the check that any appeared at all |
| `llm-pretrain-solo` | timing lines **per GPU** | `_v_llm_solo_ranks`, in the pass that already counts the ranks |

Per GPU for the solo job because a pooled count is exactly the failure that job
exists to find — one rank printing two hundred timings while three print five
sums to plenty. The four-way job logs once per iteration and has no rank to
attribute a line to, so lines and iterations are the same count there.

**The dependency this creates.** 50 is the recipe's iteration count, not a
property of the log, and the gate counts *lines*. They are the same number only
while the recipe logs every iteration. A recipe whose log interval is not 1
prints fewer lines than it ran iterations, and this floor would then fail every
healthy node in the fleet on the first sweep. Confirming that against a real
result file is part of re-capturing the `.sbatch` —
[how-to/capture-an-sbatch-from-llmb-run.md](../how-to/capture-an-sbatch-from-llmb-run.md)
— and the check is one command:

```bash
## Both should print 50 on a node that passed before this floor existed.
grep -c 'elapsed time per iteration' results/<node>/llm-pretrain.txt
grep -oE '^[0-9]+:.*train_step_timing' results/<node>/llm-pretrain-solo.txt |
    cut -d: -f1 | sort -n | uniq -c
```

Nothing else in the tree ties a gate to a count the recipe chose, which is why
this one is written down rather than left in the constant.

### Nothing at all is a different fault

`llm-pretrain` asks two questions in order: did *any* timing appear, and then
were there enough of them. `_v_llm_solo_ranks` asked only the second, so a solo
run where no rank reported failed the floor of four and was reported as `fewer
than 4 GPUs reported step timings` — which says three GPUs trained and one did
not, and points the reader at hardware. `i05-30` read that way while its log
held four lines saying the recipe half of the llmb install was missing.

The two are not the same finding and do not have the same fix. Some ranks
reporting is a per-device fault on a node that staged and started; none
reporting is staging or the container, and no GPU on that node is implicated.
So zero gets `no training step timings` — the reason the four-way gate already
gives for it, so the two jobs group together in a report rather than describing
one fault in two ways.

`VERDICT_DETAIL` carries the line count of the result file, because the next
question is always whether the job got anywhere at all. Four lines is a launch
that was refused before the container ran; four hundred is a run that started
and never reached its first step, which is a different place to look.

Note what this does *not* do: it does not consult `VERDICT_RUN_ERRORS`, and a
log carrying one of those strings **and** no timings is still reported here. The
preflight messages that produce this case — a missing recipe or an empty
`LLM_HF_HOME` — match none of them, so nothing is being hidden today. A gate
that learns to read those messages belongs above this one, not inside it.

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
the grouping keeps them in one block, while the detail names the offending GPU:

```
per-GPU step times disagree -- spread above 0.05
cov 0.074, slowest gpu 2 at 0.4740 vs 0.4202 mean per step
```

`VERDICT_MAX_COV_LLM_SOLO` ships as **0.02**, and where that came from matters
more than the number. It shipped as `0` — the check skipped — for as long as no
node had run the job, because a floor invented at a desk either drains the fleet
on day one or never fires.

The first healthy GB300 tray to complete it showed:

| | median step | above fastest |
|---|---|---|
| gpu 0 | 3319.5 ms | — |
| gpu 3 | 3330.9 ms | 0.3% |
| gpu 1 | 3349.7 ms | 0.9% |
| gpu 2 | 3363.8 ms | 1.3% |

**cov 0.0051** — 44 ms of spread on a 3.34 s step. `0.02` is four times that,
and the arithmetic of what it catches is worth stating: with one outlier among
four, `cov ≈ 0.43 × d`, so `0.02` fires at a GPU about **5% slower** than its
neighbours and `0.05` would need 12%.

One node, one run. If a second healthy tray lands nearer the line, widen it —
that is a real finding about the spread, not a failure.

Because 0 makes the spread check silent, `tests/verdict-test.sh` sets a band
explicitly and asserts the outlier is caught *and named* — otherwise shipping 0
and shipping a broken check would look identical in the suite. The three
`llm-pretrain-solo__*` fixtures are synthetic for the same reason; replace them
with real captures once a node has run it.

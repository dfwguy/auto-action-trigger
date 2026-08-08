# `llmb-run`

Reference for the tool itself, separate from how this tree uses it.
[explanation/llmb.md](../explanation/llmb.md) covers the two jobs and the install; this page covers what
`llmb-run` is, what its flags mean, and the four behaviours that surprised us.

Upstream: [NVIDIA/dgxc-benchmarking](https://github.com/NVIDIA/dgxc-benchmarking),
`cli/llmb-run/`. Everything below was read out of that repo. Where this page and
the tool disagree, the tool is right — check against `--help` and re-read
[Confirming this page](#confirming-this-page).

## What it is

A submitter, not a payload. `llmb-run` reads a workload recipe, builds a Slurm
job for it and submits it. It does not run training in your allocation; it makes
an allocation of its own.

That single fact drives the whole design of `llm-pretrain` — see
[llmb.md#why-llm-pretrain-is-not-an-sbatch](../explanation/llmb.md#why-llm-pretrain-is-not-an-sbatch).

## Command surface

```
llmb-run [-v|--verbose] COMMAND [OPTIONS]
```

| Command | Does |
|---------|------|
| `submit` | Build and submit jobs. The one this tree uses |
| `list` | Show available workloads and their configurations |
| `jobs` | `list`, `show`, `log`, `refresh`, `rebuild` over submitted job history |
| `exemplar` | Run the cloud-certification workload suite |
| `archive` | Package experiment results into an archive |

Note the subcommand is `submit`. There is no `single`, and no `prepare`.

### Selecting what to run

Four modes:

```bash
llmb-run submit -w <workload> -s <model-size> --dtype <dtype> --scale <n>
llmb-run submit -w <workload>_<size>,<workload> --dtype <dtype> --scale <n>
llmb-run submit -f <file>            # batch, from a file
llmb-run submit --max-scale <n>      # auto-discovery, everything up to n
```

Workloads are named `<workload>` or `<workload>_<model-size>`. `--scale` is a
**number of GPUs**, not nodes — 32 means 32 GPUs, which on a 4-GPU tray is 8
nodes.

### Options

| Flag | Meaning |
|------|---------|
| `-r, --repeats <N>` | Repeat each job N times |
| `-p, --profile` | Enable profiling |
| `--dry-run` | Print what would be submitted, submit nothing |
| `--force` | Bypass dtype/scale validation for one explicit task |
| `--min-scale` / `--max-scale` / `--exact-scales` | Scale selection helpers |
| `--proxy` | Use proxy scales |
| `--dump-env` | Environment snapshot, Megatron-Bridge workloads |

Note `--dry-run`, hyphenated.

### Slurm options

| Flag | Meaning |
|------|---------|
| `--nodelist <LIST>` | Restrict to specific nodes |
| `--exclude <LIST>` | Exclude nodes |
| `--reservation <NAME>` | Submit under a reservation |
| `--segment <INT>` | Slurm segment size |
| `--nice <INT>` | Lower priority; higher is later |
| `--env <KEY=VALUE>` | Environment override for the submitted job, repeatable |
| `--slurm-arg <KEY=VALUE>` | Arbitrary Slurm parameter, repeatable |

`--slurm-arg` takes `KEY=VALUE` or a bare flag, **with no leading dashes**:

```bash
llmb-run submit -w pretrain_llama3.1 -s 405b --dtype fp8 --scale 256 \
  --slurm-arg constraint=gpu --slurm-arg exclusive
```

It **refuses the keys that have dedicated flags** — `nodelist`, `exclude`,
`reservation`, `segment`, `nice`. Those must use their own flag. `job-name` and
`output` are not on that list, which is how this tree sets both.

### Environment variables

| Variable | Meaning |
|----------|---------|
| `LLMB_SKIP_PP` | Disable post-processing job submission. `1`, `true` or `yes` |
| `HF_TOKEN` | Hugging Face token |
| `RUN_CONF_*` | Settings from the config's environment section |
| `SBATCH_*`, `SLURM_*` | Slurm parameters, via the cluster config |

### Exit codes

`0` success, `1` validation error, `2` system error.

## Configuration

Configuration lives in `cluster_config.yaml`, written by the installer — **not**
in environment variables. Sections:

| Key | Holds |
|-----|-------|
| `schema_version` | `2` |
| `llmb_repo` | Repository path |
| `llmb_install` | Base install directory for workloads and data |
| `gpu_type` | `gb200`, `gb300`, `b200`, `b300`, `h100` … |
| `environment` | Environment variables, including `HF_TOKEN` |
| `slurm` | Account, and `slurm.gpu` / `slurm.cpu` partition sections |
| `workloads.installed` | Installed workloads, their venv paths and types |

## Installing

`./install.sh` from the cloned repository. It installs `uv` if absent, sets up a
Python 3.12 virtualenv, installs the CLI tools (`llmb-run`, `llmb-install`), and
then **prompts** — for cluster configuration, workload selection and `HF_TOKEN`.
The first run is interactive, not unattended.

`./install.sh -i /shared/llmb-images` shares one image directory across
installations rather than re-importing per install.

`LLMB_INSTALL` ends up holding `bin/`, `images/`, `datasets/`, `venvs/` and
`workloads/`. Budget **at least 300 GB** for a pretraining setup.

There is no dataset-staging subcommand. The installer fetches what a selected
workload needs, at selection time.

## The four things that surprised us

### 1. It submits a second job

`llmb-run` submits a **post-processing job** alongside the training job.
`LLMB_SKIP_PP=1` disables it.

For this tree that is not a preference. `actions/launch_job.sh` treats any job
on the node that is not named `bringup-<node>` or `burnin-<node>` as somebody
else's and leaves the node alone. A post-processing job would trip that gate
every cycle for as long as it existed — the node would stop testing behind a
trace line that looked correct. No job calls `llmb-run` any more, but a capture
run on the head node still sets `LLMB_SKIP_PP=1` for the same reason — see
[how-to/capture-an-sbatch-from-llmb-run.md#the-capture](../how-to/capture-an-sbatch-from-llmb-run.md#the-capture).

### 2. Scales are characterised, not permitted

Every recipe declares the GPU counts it has been characterised at, and
validation rejects anything else. These are benchmark-comparability ranges, not
statements about what the hardware can hold.

`--force` bypasses that check for one explicit task. Whether that is *sound* is
a per-recipe question — it depends entirely on the parallelism plan, and the
answer for Llama 3.1 8B is worked through in
[llmb.md#running-below-the-characterised-scale](../explanation/llmb.md#running-below-the-characterised-scale).

### 3. Minimum scales are large

| Workload | Sizes | Minimum scale |
|----------|-------|---------------|
| `pretrain_nemotron-h` | 56B only | **32 GPUs** |
| `pretrain_llama3.1` | 8B, 70B, 405B | **8 GPUs** (8B); 64 (70B); 256 (405B) |

Nothing in the collection is characterised below 8 GPUs. There is no scale-1
recipe. On a 4-GPU tray, the smallest thing that runs at all is Llama 3.1 8B
with `--force`.

### 4. Some models are gated

Recipes using gated Hugging Face repositories — Llama among them — need an
access approval on the account behind `HF_TOKEN`. **Approval is per-account and
is not carried by the token**, so a valid token still fails until the request is
granted. Request it early.

Nemotron-H, by contrast, trains on synthetic data and stages nothing.

## Confirming this page

Read from the repository rather than a running install, so treat it as a guide
to what to check, not as ground truth. On the head node:

```bash
llmb-run --help
llmb-run submit --help
llmb-run list                    # workloads, sizes, characterised scales
```

Getting the batch script a submission actually produces is a separate procedure:
[how-to/capture-an-sbatch-from-llmb-run.md](../how-to/capture-an-sbatch-from-llmb-run.md).

The recipe tables under each workload directory in the upstream repo carry the
per-GPU-type parallelism plans — that is where the scale ranges and the TP/PP/DP
configuration come from, and what to re-read when a recipe version changes.

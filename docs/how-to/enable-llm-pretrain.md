# Enable the LLM pre-training jobs

Two jobs, one install. Why they are shaped the way they are is
[explanation/llmb.md](../explanation/llmb.md).

## 1. Install on the head node

Head node only, once per CPU architecture — `nvl72` is ARM, and the image is
architecture-specific.

```bash
export HF_TOKEN=hf_...            # this run only; never written to a node
./build_llmb.sh                   # installs the LLMB_REF in SETTINGS
./build_llmb.sh -l                # what is present, what is not
```

To move versions, edit `LLMB_REF` in `SETTINGS` and re-run. `-l` prints both the
ref `SETTINGS` asks for and the one actually checked out, so a drift between
them is visible. A ref that does not exist lists the tags that do.

It leaves `$LLMB_INSTALL/src` (the pinned collection), `bin/`, `venvs/`,
`workloads/`, `datasets/`, `images/*.sqsh`, a `cluster_config.yaml`, and
`$LLMB_INSTALL/hf` holding the tokenizer cache.

Two things to expect:

- **The collection's `install.sh` prompts** — for cluster settings, workload
  selection and `HF_TOKEN` — so the first run is interactive, not unattended. It
  is passed `-i "$LLMB_INSTALL/images"` so repeat installs share one image
  directory instead of re-importing.
- **There is no dataset staging subcommand.** The installer fetches what a
  selected workload needs. `-d` therefore **checks** that `$HF_HOME` is
  populated rather than fetching it — an empty cache is a two-hour failure on a
  node with no route out, and it is worth catching on the head node instead.
  `-i` re-stages the image into `containers/` only.

If the installer stops with `mkdir: cannot create directory '/var/lib/enroot'`,
the enroot overrides did not reach it — do not re-run it under `sudo`. See
[explanation/llmb.md#the-installers-enroot-import](../explanation/llmb.md#the-installers-enroot-import).

Llama is a **gated** Hugging Face repo: it needs an access approval on the
account behind `HF_TOKEN`, and approval is per-account rather than carried by
the token. Get that first or the staging fails.

`cluster_config.yaml` (schema v2) is where `llmb_install`, `gpu_type` and the
`slurm` settings live — not environment variables. Set `gpu_type: gb200` and the
tray's GPU count there. See
[reference/llmb-run.md#configuration](../reference/llmb-run.md#configuration).

The image is copied into `containers/` as well, so `actions/file_copy.sh` rsyncs
it to `/tmp/containers/` on each node like every other image. Without that step
every node streams the same multi-GB squashfs off one filer at the same moment.
The NGC credentials are the ones `./build_containers.sh -L` already writes — see
[build-containers.md#logging-in-to-ngc](build-containers.md#logging-in-to-ngc).
No credential ever reaches a compute node.

## 1b. Or adopt an install that already exists

A cluster that already has an llmb-run install does not need a second one. Point
`LLMB_INSTALL` at it and ask:

```bash
./build_llmb.sh -l                # exits non-zero if anything the jobs need is missing
```

The search does not assume this script's layout: it finds the `llmb-run`
executable wherever it is — including a `llmb_venv/` *beside* the install root —
the `cluster_config.yaml`, the images and the HF cache. Whatever it resolved by
fallback is printed as `LLMB_BIN=` / `LLMB_CONFIG=` / `LLMB_IMAGES=` / `LLMB_HF=`
lines. **Put those in `SETTINGS`**: the search ran here, and the jobs run on the
compute nodes.

Then set `LLMB_REF` to the version the report says the install actually is, or
empty it to skip the gate — with the floors in `parsers/*/verdict.sh` re-read
either way. See
[explanation/llmb.md#adopting-an-existing-install](../explanation/llmb.md#adopting-an-existing-install).

## 2. Enable `llm-pretrain`

In order, because each step is checkable on its own:

1. `./build_llmb.sh` on the head node, then `-l` to confirm.
2. `cp "$LLMB_INSTALL"/images/nvidia+nemo+*.sqsh "$CONTAINER_DIR"/` — the job
   reads the image from the container share, not from the install. See
   [capture-an-sbatch-from-llmb-run.md#getting-the-image-onto-the-nodes](capture-an-sbatch-from-llmb-run.md#getting-the-image-onto-the-nodes).
3. `actions/launch_job.sh --test llm-pretrain --explain` on one node — it prints
   the launch it would run without running it.
4. Drop `--explain` on that one node and read `results/<node>/trigger.log` and
   `results/<node>/llm-pretrain.txt`.
5. Capture that output as a fixture in `tests/fixtures/` and check it against
   `_v_gate_llm_pretrain` with `./tests/verdict-test.sh`.
6. Only then add `llm-pretrain` to `BENCHMARKS`.

The job's four ranks and the tray's GPU count have to agree; both are set for
`nvl72` in `jobs/nvl72/llm-pretrain.sbatch`. On a platform with a different GPU
count, both move together — and so does the NUMA divisor, which is
[explanation/llmb.md#the-numa-binding](../explanation/llmb.md#the-numa-binding).

## 3. Filling in the solo training command

`jobs/nvl72/llm-pretrain-solo.sbatch` now carries the command, captured from a
real scale-1 submission — it is the sibling's `run_script.py` invocation with
`--num_gpus 1`. Nothing to fill in; this section is what to check if you change
it.

`--dry-run` will **not** give you a replacement. It prints the task list and
nothing about the script; the command has to come from the generated artifacts,
which is [capture-an-sbatch-from-llmb-run.md](capture-an-sbatch-from-llmb-run.md).

Whatever replaces it has to be a **single-process** invocation: no `torchrun`,
no `srun`, no distributed launcher. The four copies are already four Slurm
tasks, and a launcher inside them would fan out again.

Do not remove `--gpus-per-task=1`, the `WORLD_SIZE=1 RANK=0 LOCAL_RANK=0`
overrides, or `srun --label` — all three are load-bearing, and the failure when
they go is quiet. See
[explanation/llmb.md#keeping-the-four-solo-copies-independent](../explanation/llmb.md#keeping-the-four-solo-copies-independent).

## 4. Set the spread floor

`VERDICT_MAX_COV_LLM_SOLO` ships as **0**, which skips the spread check
entirely. Set it from what a healthy node on this platform actually shows, once
one has run the job — a made-up floor either drains the fleet on day one or
never fires.

## If a launch is refused

Every refusal writes `FAIL` and its reason into the result file, so
`results/<node>/llm-pretrain.txt` names it. In order: the step did not receive
the whole node, no `nvidia+nemo` image in `/tmp/containers` or `$CONTAINER_DIR`,
no `run_script.py` under `$LLMB_INSTALL`, and no pre-staged `$HF_HOME`.

Anything absent from `$HF_HOME` at launch is a failed run, not a slow one.
`build_llmb.sh -d` is what fixes it, and it runs on the head node.

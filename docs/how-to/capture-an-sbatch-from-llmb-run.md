# Capture the sbatch `llmb-run` would run

For turning an `llmb-run` recipe into a hard-set `jobs/$JOBS/*.sbatch` that this
tree owns. `llmb-run` is used **once, on the head node, as a source** — it is not
in the launch path afterwards.

The tool has no "export the script" mode, so this is a capture, not an export.
What follows is where the script actually is, how to get it, how to get the
image out with it, and what to keep. The tool itself is
[reference/llmb-run.md](../reference/llmb-run.md); why the tree froze it is
[explanation/llmb.md](../explanation/llmb.md).

## Where the sbatch is depends on the launcher

Each workload's `metadata.yaml` carries `run.launcher_type`, and it decides which
of two very different things happens:

| `launcher_type` | What `llmb-run submit` does | The script to capture |
|---|---|---|
| `sbatch`, `configured_sbatch` | Builds an `sbatch` argv itself and calls it on the recipe's `launch.sh`, from the workload directory, with a prepared environment | `launch.sh`, plus that environment and that argv |
| `nemo2`, `megatron_bridge` | Runs `./launch.sh` as an ordinary host process. `launch.sh` calls `Megatron-Bridge/scripts/performance/setup_experiment.py`, and NeMo-Run **generates a batch script and submits it** | the generated `*_sbatch.sh` in the experiment run directory |

Llama 3.1 and Nemotron-H — the two that matter here — are the second kind. Their
`launch.sh` is not a batch script and never reaches `sbatch`; it is a wrapper
that computes `CONFIG_OVERRIDES` from `MODEL_SIZE`, `DTYPE`, `GPU_TYPE` and
`JOB_TOTAL_GPUS` and hands them to a generator. Reading `launch.sh` in the
upstream repo tells you nothing about what runs, which is why the capture has to
happen on a cluster with a real install.

## Where NeMo-Run leaves it

This is the part that costs an hour if you go looking in the wrong place. Under
`$LLMB_INSTALL/workloads/<workload>/experiments/<experiment>/<run>/`:

| Path | Holds |
|---|---|
| `<run>/<name>_sbatch.sh` | **the generated batch script.** At the run level, *not* in the task subdirectory |
| `<run>/<task>/scripts/<name>.sh` | the in-container command the `srun` line invokes |
| `<run>/<task>/configs/*_executor.yaml` | every `#SBATCH` value in declarative form, plus `container_image`, `container_mounts`, `srun_args` and `env_vars` |
| `<run>/<task>/configs/ConfigContainer.yaml` | the full model and training configuration |
| `<run>/<task>/log-*.out` | the run's own output — the fixture a verdict floor gets set from |

The run directory ends in a Unix timestamp, so the newest one is the one you just
submitted. Two traps: the paths are long enough that a careless glob produces
`File name too long` from `cat`, and `ls -d …/*/*/*` matches every experiment
ever run, not the newest.

`scontrol write batch_script <jobid> -` gets the same script straight from Slurm
and is worth knowing, but only works **while the job is in the queue** — Slurm
discards it on completion. The on-disk copy above survives, so prefer it.

`--dry-run` prints the task list and nothing about the script. It confirms
validation, and that is all it is good for.

## The capture

On the head node, as `JOB_USER`, from the install directory — `llmb-run` reads
`cluster_config.yaml` relative to the current directory, which takes precedence
over `$LLMB_INSTALL`:

```bash
mkdir -p /tmp/llmb-capture
cd "$LLMB_INSTALL"
export LLMB_SKIP_PP=1            # else a second job appears; see ../explanation/llmb.md#the-post-processing-job

llmb-run list | tee /tmp/llmb-capture/list.txt
llmb-run -v submit -w pretrain_llama3.1 -s 8b --dtype fp8 --scale 4 --force \
    --nodelist <node> --nice 20 2>&1 | tee /tmp/llmb-capture/submit.log
```

`--force` is what allows a scale below the recipe's characterised floor; whether
that is sound is a per-recipe question, worked through in
[explanation/llmb.md#running-below-the-characterised-scale](../explanation/llmb.md#running-below-the-characterised-scale).

Let it run — a 4-GPU 8B run is about five minutes, and the log is the fixture.
Then collect, driven off the job id the submission printed:

```bash
J=<jobid>
R=$(ls -dt "$LLMB_INSTALL"/workloads/pretrain_llama3.1/experiments/*/*/ | head -1)
T=$(ls -d "$R"*/ | head -1)

cp "$R"/*_sbatch.sh          /tmp/llmb-capture/
cp "$T"/scripts/*.sh         /tmp/llmb-capture/in-container-command.sh
cp "$T"/configs/*.yaml       /tmp/llmb-capture/
cp "$T"/log-*.out            /tmp/llmb-capture/
cp "$LLMB_INSTALL"/cluster_config.yaml /tmp/llmb-capture/
sacct -j "$J" -o JobID,JobName%40,NNodes,NTasks,ReqTRES%50,Elapsed,State,ExitCode \
    > /tmp/llmb-capture/sacct.txt
```

Read the long lines with `fold -w 120` — the `srun` invocation and the
in-container `python` command are single lines several hundred characters wide,
and a terminal silently truncates both.

## Getting the image onto the nodes

The captured `srun` names the image by its path inside the llmb install
(`$LLMB_INSTALL/images/nvidia+nemo+<version>.sqsh`). A frozen job must not read
it from there: the install is one NFS directory, every node would pull a
multi-gigabyte squashfs across the wire for every run, and the job would still
depend on the install being present exactly as `llmb-run` built it.

Copy it into `CONTAINER_DIR` instead, where every other job's image lives:

```bash
cp "$LLMB_INSTALL"/images/nvidia+nemo+*.sqsh "$CONTAINER_DIR"/
```

Nothing else has to change. `actions/file_copy.sh` rsyncs `$CONTAINER_DIR/*.sqsh`
into `NODE_CONTAINER_DIR` (`/opt/containers` by default) on each node, and the frozen job resolves node-local
first with the shared copy as fallback, exactly as every other job does —
[explanation/containers.md#how-the-caching-works](../explanation/containers.md#how-the-caching-works).

Keep the upstream filename. It carries the framework version, which is the only
thing tying a result to a recipe once `llmb-run` is out of the picture.

The image contains the recipe entry point at
`/opt/Megatron-Bridge/scripts/performance/run_script.py`, and both LLM jobs run
that copy. Their only external data mount is the standalone `LLM_HF_HOME`
cache. Generated NeMo files stay under `/mnt/nemo` in the writable container,
so `$LLMB_INSTALL` is not a runtime dependency.

Verify a replacement image before enabling it:

```bash
srun -w <node> --ntasks=1 --container-image="$CONTAINER_DIR"/nvidia+nemo+<version>.sqsh \
     ls /opt/Megatron-Bridge/scripts/performance/
```

That directory must list `run_script.py`.

## What to keep from the captured script

The generated script is written for the machine that generated it. Roughly half
of it is this tree's job instead:

| In the capture | Keep or drop |
|---|---|
| `--nodes`, `--ntasks-per-node`, `--exclusive`, `--mem=0`, `--segment` | **Keep** — the allocation shape the recipe needs, and the reason to capture at all |
| `--gres` | The executor leaves it `null` and the partition supplies it; `sacct` shows what was really requested. Say it explicitly, per [reference/jobs.md#the-allocation-header](../reference/jobs.md#the-allocation-header) |
| `--time` | Keep as the step limit, and set `#SBATCH -t` above it, per [reference/jobs.md#two-time-limits-and-the-order-they-fire-in](../reference/jobs.md#two-time-limits-and-the-order-they-fire-in) |
| `--account`, `--partition`, `--job-name`, `--output`, `--nodelist` | **Drop.** `launch_job.sh` supplies the account, the node, the job name the gates match and the result path; a header that sets them fights it |
| `--nice`, `--nodelist` in `additional_parameters` | Evidence that both flags reach the job through the nemo path — nothing to carry over |
| `container_image` | Keep, resolved through `CONTAINER_DIR` as above |
| `container_mounts`, `srun_args`, `env_vars` | Keep. The `srun_args` (`--mpi=pmix`, `--no-container-mount-home`, `--container-writable`) are load-bearing |
| The in-container `python` line | **Keep verbatim first.** This is the payload. Change it only once it has run unmodified |
| `print_sha.sh`, `/nemo_run` mounts, `_TASKS`/`_TUNNELS`/`_DONE` files, requeue logic | Drop. Experiment bookkeeping for `llmb-run jobs`, which nothing here uses |
| Post-processing submission | Drop |

Adding the resulting file and its gate is [add-a-benchmark.md](add-a-benchmark.md).

## What a capture has to record to be re-doable

A captured script is a snapshot of one recipe version on one GPU type. Without
these, a later capture that differs cannot be told from a broken one:

- `LLMB_REF` and the install's own version — see
  [explanation/llmb.md#pinning-the-collection](../explanation/llmb.md#pinning-the-collection)
- `gpu_type` from `cluster_config.yaml`, and the `cluster_config.yaml` itself
- The exact `llmb-run submit` line, including `--force`
- Everything `/tmp/llmb-capture` collected above
- One `log-*.out` from a healthy node

Keeping those together per model is what makes the frozen `.sbatch` reviewable
against its source later, when the recipe has moved on and the tree has not.

# auto-action-trigger

Automated node bring-up and validation framework for HPC clusters managed by **Bright Cluster Manager (BCM)**. When a node boots and its device status becomes `UP`, BCM monitoring triggers fire three action scripts that run hardware health checks, cache container images on local disk, and sequence through Slurm benchmark jobs — draining the node in Slurm automatically on any failure.

```
Node boots → BCM device status = UP
    ├── NodeHealthTrigger → node_health.sh
    │       Compares hardware/software state against a known-good baseline.
    │       Sets node IDLE (all checks pass) or DOWN with a reason (any fail).
    │
    ├── FileCopyTrigger → file_copy.sh
    │       Rsyncs containers/ to /tmp/containers/ so job start reads the image
    │       off local disk. Silent no-op if there is nothing to copy.
    │
    └── LaunchJobTrigger → launch_job.sh
            Sequences through benchmarks (dcgmi-r1 → dcgmi-r3 → allreduce).
            Submits the next Slurm job when the node is idle and the prior run passed.
            Drains the node if a benchmark fails or runs too long.
```

All three triggers fire continuously while the device is UP (`duringactions`), so they re-evaluate on each BCM monitoring cycle without manual intervention.

This page covers what has to be in place, how to stand the framework up, and the commands a bringup needs day to day. Everything else is in [docs/](docs/):

`docs/` is organised by [Diátaxis](https://diataxis.fr/) — by what you are
doing, not by which script the page is about. [docs/README.md](docs/README.md)
is the compass; the four entry points are:

| If you are… | Start at |
|------|--------|
| new to this and want it working on one node | [docs/tutorials/](docs/tutorials/) — a first bringup, the trigger chain, reading the fleet through Slurm |
| trying to get something specific done | [docs/how-to/](docs/how-to/) — enabling benchmarks, pausing, managing drains, diagnosing a failure |
| looking up a setting, a flag, or what a trace line means | [docs/reference/](docs/reference/) — `SETTINGS`, the job catalog, the 38 health checks, every operator script |
| trying to understand why it works this way | [docs/explanation/](docs/explanation/) — the sequencer, derived verdicts, drain recovery, containers |

## Prerequisites

### The automation user

A local user named by `JOB_USER` — `cmods` as shipped — must exist on the **headnode and every compute node** in the cluster. It is the only place the account is named: the tree path and the llmb install derive from it, so pointing the framework at a dedicated automation account is one line in `SETTINGS` and no code change. See [docs/reference/settings.md#accounts-and-paths](docs/reference/settings.md#accounts-and-paths).

- The tree is deployed at `$BRINGUP_HOME`, which defaults to `/home/$JOB_USER/bringup/` — that home directory is the deployment root.
- `node_health.sh` runs as whatever user BCM invokes it as, but it `chown`s its log output to `$JOB_USER`. The account must therefore be resolvable on the node at the time the script runs.
- `launch_job.sh` submits Slurm jobs via `su - $JOB_USER`, so it must be a valid login user with access to the Slurm environment (`/etc/profile.d/modules.sh` and the `slurm` module), and with whatever Slurm association the site requires — an `sbatch` refused for a missing association lands in `trigger.log` rather than being swallowed.
- It must have write access to `logs/`, `results/` and `reports/` under the deployment root on the headnode.
- If the home directory is shared via NFS or another network filesystem, compute nodes will inherit it automatically. If not, `$BRINGUP_HOME` must be accessible on each compute node (e.g., via a shared filesystem mount).

The container images do **not** have to live under that home directory: `CONTAINER_DIR` is its own setting, so they can sit on whatever bulk share the site has, and `CONTAINER_DIR_HEAD` covers the case where the headnode mounts that share at a different path than the compute nodes do. See [docs/explanation/containers.md#one-share-two-mount-points](docs/explanation/containers.md#one-share-two-mount-points).

`jobs/nvl72/nvsm.sbatch` runs only on **DGX** systems and additionally needs a passwordless sudoers grant for `$JOB_USER` on every compute node — see [docs/how-to/enable-nvsm.md](docs/how-to/enable-nvsm.md). It is the only job with either requirement, and for both reasons it is not in the default `BENCHMARKS` list.

### Required software

| Software | Used by |
|----------|---------|
| Bright Cluster Manager (`cmsh`) | `pre-post/create-action-trigger.sh`, `pre-post/delete-action-trigger.sh` |
| Slurm (`sinfo`, `scontrol`, `sbatch`, `squeue`) | `node_health.sh`, `launch_job.sh`, all `.sbatch` jobs |
| `nvidia-smi` | `node_health.sh` (GPU checks) |
| `ibstatus`, `mlxlink`, `perfquery` | `node_health.sh` (InfiniBand checks) |
| `lspci` | `node_health.sh` (PCIe checks) |
| `numactl` | `node_health.sh` (NUMA checks) |
| `dmidecode` | `node_health.sh` (BIOS/memory checks) |
| `dcgmi` | `jobs/nvl72/dcgmi-r1.sbatch` … `jobs/nvl72/dcgmi-r4.sbatch` |
| `nvsm` | `jobs/nvl72/nvsm.sbatch` (DGX only; runs on the host, no container, needs root — see [docs/how-to/enable-nvsm.md](docs/how-to/enable-nvsm.md)) |
| `nvidia-imex-ctl` | `node_health.sh` (IMEX checks, GB series only) |
| `enroot` | `build_containers.sh` (headnode for the fetch pass, compute nodes for the source-build pass; pyxis already needs it there) |
| `squashfs-tools` | `build_containers.sh` (optional — shrinks the staged package set) |
| `dshbak` | `status-check.sh` |
| `rsync` | `actions/file_copy.sh` (optional) |

### Operational scripts (headnode only)

The following scripts are run manually by an operator from the headnode and do not require the `cmods` user — they only need standard Slurm CLI access and read/write access to the repo directory:

| Script | Requires |
|--------|---------|
| `status-check.sh` | `sinfo`, `dshbak`, read access to `results/` |
| `check_squeue.sh` | `squeue`; `-j` also uses `sinfo` and `scontrol` |
| `daily-report.sh` | `sinfo`, read access to `results/`; write access to wherever `-o` points |
| `health-check.sh` | `sinfo`, `scontrol`, read access to `logs/` and `valid-config/` |
| `health-check.sh --refresh` | write access to `logs/<node>/` |
| `trigger-debug.sh` | `cmsh`, `sinfo`, read access to `results/` |
| `trigger-log.sh` | read access to `results/` and `logs/` |
| `watch-rack.sh` | `sinfo` |
| `single-node-purge.sh` | write access to `results/` |
| `kill-jobs.sh` | `squeue`, `scancel` as `JOB_USER` or root; `-p` also needs write access to `SETTINGS` |
| `set-valid-default.sh` | write access to `valid-config/` |
| `pre-post/create-action-trigger.sh` | `cmsh` (BCM admin access) |
| `pre-post/delete-action-trigger.sh` | `cmsh` (BCM admin access) |

Draining and resuming nodes needs Slurm privilege — see [docs/reference/layout.md](docs/reference/layout.md#slurm-permissions).

## First-time setup

### 1. Set up the BCM actions and triggers

```bash
bash pre-post/create-action-trigger.sh
```

This registers three actions (`node_health_action`, `file_copy_action`, `launch_job_action`) and three triggers (`NodeHealthTrigger`, `FileCopyTrigger`, `LaunchJobTrigger`) in BCM monitoring.

It is safe to re-run: each object is removed before it is added, so an existing registration is replaced rather than colliding. Removals are silent — on a first run there is nothing to remove — but the adds report `ok:` or `FAILED:` per object and the script exits non-zero if any failed. A registration that fails quietly is how you end up believing a node is being health-checked when it is not.

To remove them:

```bash
bash pre-post/delete-action-trigger.sh
```

### 2. Download the container images

```bash
./build_containers.sh -L     # log in to nvcr.io — once per machine, needed for the private-org images
./build_containers.sh
```

Run on the headnode, once per CPU architecture in the cluster. Which images it downloads is `CONTAINERS` in `SETTINGS`, which ships as `hpc-benchmarks nvbandwidth mnubergemm` — exactly what the default `BENCHMARKS` list needs. Add an image there when you add the job that uses it; `-A` adds `nvloom`, the one image no registry publishes.

`-L` is not optional for the shipped list: `nvbandwidth` and `mnubergemm` come from a private NGC org, and without credentials they fail to download and their two jobs then fail on every node. `./build_containers.sh -l` says which images are actually present. A site that would rather not need an NGC key drops both names from `CONTAINERS` *and* `BENCHMARKS`.

Downloading is the default and, without `-S`, the only path: an image that cannot be pulled reports why rather than starting a source build. `-L` writes `~/.config/enroot/.credentials`. See [docs/explanation/containers.md](docs/explanation/containers.md).

### 3. Establish a valid-config baseline

Run the health script manually on a node that has been fully validated, then capture its output as the reference:

```bash
bash set-valid-default.sh <node_name>
# e.g. bash set-valid-default.sh node001
```

This copies `logs/<node_name>/` to `valid-config/<node_name>/` and symlinks it as `valid-config/default/`. All subsequent health checks diff against this baseline.

It is a **copy**, deliberately, and pointing `valid-config/default` at a live `logs/<node>/` instead is the one edit to avoid here: the checks re-run on a cadence, so the baseline would follow that node's drift and the fleet would keep agreeing with it. `node_health.sh` refuses to run rather than overwrite its own baseline. See [docs/explanation/health-cadence.md#the-golden-baseline](docs/explanation/health-cadence.md#the-golden-baseline).

### 4. Make a SETTINGS file

Everything configurable lives in one file. `SETTINGS.default` ships with the framework and is read when there is no `SETTINGS`; `SETTINGS` is what a site edits and is never overwritten by an upgrade.

```bash
cp SETTINGS.default SETTINGS
```

Editing `SETTINGS.default` in place works until the next tarball drop replaces it. A `SETTINGS` only has to carry the lines you changed — anything it leaves out falls back to the shipped default. See [docs/reference/settings.md](docs/reference/settings.md).

### 5. Choose the benchmark list

The active list is `BENCHMARKS` in `SETTINGS`; which subset a site should run depends on its delivery methodology. See [docs/reference/jobs.md](docs/reference/jobs.md).

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 nvbandwidth allreduce allreduce-forcesharp \
            alltoall allreduce-nonvlink alltoall-nonvlink"
```

### 6. Decide whether to burn in

Burn-in is a second list, queued alongside the sweep, and off until you ask for it:

```bash
RUN_BURNIN=no
BURNIN="mnubergemm"
```

`mnubergemm` is 12 runs of a ~6-hour step, one job at a time, so a node is under burn-in for about three days. It is not gated on the benchmarks passing — it is ordered behind them by `#SBATCH --nice` in the job files (the dcgmi gates at 1-4, the rest of the sweep at 20, burn-in at 100000), so a benchmark retry queued mid-burn-in goes ahead of the runs still waiting rather than behind all of them. It does not interrupt the run already on the node: every job is `--exclusive`.

`MAX_JOB_HOURS` ships at `7` to clear a single burn-in run — lower it and the sequencer drains healthy nodes mid-run for a timeout. The image is downloaded by default even though the list is off, so turning it on does not mean a fleet-wide failure while the image catches up. See [docs/reference/settings.md](docs/reference/settings.md#burn-in).

### 7. Decide whether failures should drain

Both drain switches ship **off**, so no failure takes a node out of service:

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # health check mismatched the baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # benchmark sweep failed, or a job ran past MAX_JOB_HOURS
```

Turn them on once the failures being reported are real ones. Health-check drains are the riskier half — a bad baseline drains the whole cluster on the first monitoring cycle — so bring that one up only after `bash health-check.sh --summary` reads clean. See [docs/how-to/manage-drains.md](docs/how-to/manage-drains.md).

### 8. Decide how often health checks re-run

```bash
HEALTH_INTERVAL_HOURS=4         # after a clean run
HEALTH_RETRY_INTERVAL_HOURS=1   # after a run that found something
```

The checks re-run on this cadence on every node, so a node repaired between cycles clears its own health drain and a node that regresses is noticed without anyone asking. `0` on both restores the older behaviour, where nothing re-ran until `health-check.sh --refresh` said so. See [docs/explanation/health-cadence.md](docs/explanation/health-cadence.md).

## Operating a bringup

```bash
bash status-check.sh                      # per-node benchmark status, all nodes
bash status-check.sh ink50-dh01-h20        # one rack (bare prefix)
bash status-check.sh -t allreduce          # one benchmark (repeatable, globs OK)
bash status-check.sh -s                    # node lists per status, no reasons
bash daily-report.sh                      # TSV table: slurm state + status + metrics
bash daily-report.sh -c -o reports/r.csv  # same rows as CSV, and keep a copy
bash watch-rack.sh "rack01-node[1-32]"    # live view of DOWN/drained nodes
bash check_squeue.sh                      # the whole queue in one table
bash check_squeue.sh -j 121918            # one job, plus its nodes' state and any reservation
```

A job stuck at `ReqNodeNotAvail` is answered by `check_squeue.sh -j` — the
reason names a condition, not the nodes behind it. See
[docs/how-to/diagnose-nothing-running.md](docs/how-to/diagnose-nothing-running.md#reading-the-queue).

A node that has stopped testing:

```bash
bash trigger-log.sh                       # read the traces: is it firing, and what did it decide
bash trigger-log.sh ink50-dh01-h20-11     # one node, with its raw trace
bash trigger-debug.sh ink50-dh01-h20      # walk BCM → sbatch, name the broken link
```

Start with `trigger-log.sh` — it reads what the sequencer already wrote down and
separates the two cases that look identical from the outside: logs stale means
nothing is running the script (a trigger problem, go to `trigger-debug.sh`), logs
fresh with nothing submitted means the script is running and a gate is closed
(the reason is already in the trace).

A node that has been drained:

```bash
bash health-check.sh                      # every failed health check, grouped by check
sinfo -n node001 -o '%T %E'               # state and reason
bash health-check.sh --diff node001       # diff its health output vs the baseline
scontrol update nodename=node001 state=RESUME
```

Stop the whole framework for a maintenance window, without unregistering it from BCM — in `SETTINGS`, effective fleet-wide on the next monitoring cycle:

```bash
PAUSE_JOBS=yes             # no benchmarks submitted; queued ones cancelled
PAUSE_HEALTH_CHECKS=yes    # no health checks run; Slurm untouched
PAUSE_CONTAINER_COPY=yes   # no new rsync into /tmp/containers
```

Nothing is lost — results stay, the sweep resumes where it stopped. One already-running benchmark per node is left to finish. To empty the queue now instead:

```bash
bash kill-jobs.sh -n                      # list what would be cancelled, change nothing
bash kill-jobs.sh -p                      # pause, then cancel every job of ours
bash kill-jobs.sh ink50-dh01-i01          # one node or glob; no -p, so the sweep resumes next cycle
```

`kill-jobs.sh` matches on our own job names rather than on the account, so it leaves anything else `cmods` owns alone, and it runs from any directory. See [docs/how-to/pause-and-resume.md](docs/how-to/pause-and-resume.md) and [emptying the queue](docs/how-to/pause-and-resume.md#emptying-the-queue-now).

A drain reason containing `auto-retry` is the sequencer's own — it clears it on the next retry pass, so resuming by hand only starts the next sweep sooner. Any other reason is an operator drain, and the sequencer will neither clear it nor queue work behind it.

Re-run health checks, or start a node's benchmarks over after a hardware swap:

```bash
bash health-check.sh --refresh node001     # ahead of the cadence
bash health-check.sh --explain node001    # when is it next due, and what did the last run find
bash single-node-purge.sh node001
```

Full command reference in [docs/reference/scripts.md](docs/reference/scripts.md); retry and drain rules in [docs/explanation/sequencing.md](docs/explanation/sequencing.md).

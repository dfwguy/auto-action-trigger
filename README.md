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
            Sequences through benchmarks (dcgm → allreduce → alltoall).
            Submits the next Slurm job when the node is idle and the prior run passed.
            Drains the node if a benchmark fails or runs too long.
```

All three triggers fire continuously while the device is UP (`duringactions`), so they re-evaluate on each BCM monitoring cycle without manual intervention.

This page covers what has to be in place, how to stand the framework up, and the commands a bringup needs day to day. Everything else is in [docs/](docs/):

| Page | Covers |
|------|--------|
| [architecture.md](docs/architecture.md) | Trigger chain in detail, directory layout, runtime paths |
| [settings.md](docs/settings.md) | `SETTINGS` — the job, health-check and parser sets, the two drain switches, and the retry policy |
| [sequencer.md](docs/sequencer.md) | `launch_job.sh` — sweep order, retry and drain rules, result-path ownership, Slurm permissions |
| [health-checks.md](docs/health-checks.md) | `node_health.sh` and `health-checks/$HEALTHCHECKS/` — every check, the check file format, adding a set for another platform |
| [benchmarks.md](docs/benchmarks.md) | The `jobs/$JOBS/` catalog, test-plan coverage, what to set before enabling a job, adding a new one, and where a pass is decided (`parsers/$PARSERS/verdict.sh`) |
| [containers.md](docs/containers.md) | `build_containers.sh` — why images are local, the two-pass source build, per-image notes |
| [nvsm.md](docs/nvsm.md) | The sudoers grant and platform definition files `jobs/nvl72/nvsm.sbatch` needs |
| [operations.md](docs/operations.md) | Full operator command reference |

## Prerequisites

### The `cmods` user

A local user named `cmods` must exist on the **headnode and every compute node** in the cluster.

- All scripts assume the repo is deployed at `/home/cmods/bringup/`. The `cmods` home directory is the deployment root.
- `node_health.sh` runs as whatever user BCM invokes it as, but it `chown`s its log output to `cmods:cmods`. The `cmods` user must therefore be resolvable on the node at the time the script runs.
- `launch_job.sh` submits Slurm jobs via `su - cmods`, so `cmods` must be a valid login user with access to the Slurm environment (`/etc/profile.d/modules.sh` and the `slurm` module).
- The `cmods` user must have write access to `/home/cmods/bringup/logs/`, `/home/cmods/bringup/results/`, and `/home/cmods/bringup/reports/` on the headnode.
- If the home directory is shared via NFS or another network filesystem, compute nodes will inherit it automatically. If not, `/home/cmods/bringup/` must be accessible on each compute node (e.g., via a shared filesystem mount).

`jobs/nvl72/nvsm.sbatch` runs only on **DGX** systems and additionally needs a passwordless sudoers grant for `cmods` on every compute node — see [docs/nvsm.md](docs/nvsm.md). It is the only job with either requirement, and for both reasons it is not in the default `BENCHMARKS` list.

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
| `dcgmi` | `jobs/nvl72/dcgm.sbatch`, `jobs/nvl72/dcgm-r2.sbatch`, `jobs/nvl72/dcgm-r4.sbatch` |
| `nvsm` | `jobs/nvl72/nvsm.sbatch` (DGX only; runs on the host, no container, needs root — see [docs/nvsm.md](docs/nvsm.md)) |
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
| `status-daily-report.sh` | read access to `results/`, write access to `reports/` |
| `health-check.sh` | `sinfo`, `scontrol`, read access to `logs/` and `valid-config/` |
| `node-health-refresh.sh` | write access to `logs/<node>/` |
| `sync-check.sh` | read access to `logs/` and `valid-config/` |
| `trigger-debug.sh` | `cmsh`, `sinfo`, read access to `results/` |
| `watch-rack.sh` | `sinfo` |
| `single-node-purge.sh` | write access to `results/` |
| `set-valid-default.sh` | write access to `valid-config/` |
| `pre-post/create-action-trigger.sh` | `cmsh` (BCM admin access) |
| `pre-post/delete-action-trigger.sh` | `cmsh` (BCM admin access) |

Draining and resuming nodes needs Slurm privilege — see [docs/sequencer.md](docs/sequencer.md#slurm-permissions).

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

### 2. Build the container images

```bash
./build_containers.sh
```

Run on the headnode, once per CPU architecture in the cluster. Which images it builds is `CONTAINERS` in `SETTINGS`, which ships as `hpc-benchmarks` alone — that is all the default `BENCHMARKS` list needs. Add an image there when you add the job that uses it; `-A` builds everything the script knows about. See [docs/containers.md](docs/containers.md).

### 3. Establish a valid-config baseline

Run the health script manually on a node that has been fully validated, then capture its output as the reference:

```bash
bash set-valid-default.sh <node_name>
# e.g. bash set-valid-default.sh node001
```

This copies `logs/<node_name>/` to `valid-config/<node_name>/` and symlinks it as `valid-config/default/`. All subsequent health checks diff against this baseline.

### 4. Make a SETTINGS file

Everything configurable lives in one file. `SETTINGS.default` ships with the framework and is read when there is no `SETTINGS`; `SETTINGS` is what a site edits and is never overwritten by an upgrade.

```bash
cp SETTINGS.default SETTINGS
```

Editing `SETTINGS.default` in place works until the next tarball drop replaces it. A `SETTINGS` only has to carry the lines you changed — anything it leaves out falls back to the shipped default. See [docs/settings.md](docs/settings.md).

### 5. Choose the benchmark list

The active list is `BENCHMARKS` in `SETTINGS`. The default holds only jobs whose dependencies are always available; which subset a site should run depends on its delivery methodology. See [docs/benchmarks.md](docs/benchmarks.md).

### 6. Decide whether failures should drain

Both drain switches ship **off**, so no failure takes a node out of service:

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # health check mismatched the baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # benchmark sweep failed, or a job ran past MAX_JOB_HOURS
```

Turn them on once the failures being reported are real ones. Health-check drains are the riskier half — a bad baseline drains the whole cluster on the first monitoring cycle — so bring that one up only after `bash health-check.sh --summary` reads clean. See [docs/operations.md](docs/operations.md#disabling-drains).

## Operating a bringup

```bash
bash status-check.sh                      # per-node benchmark status, all nodes
bash status-check.sh ink50-dh01-h20        # one rack (bare prefix)
bash status-check.sh -t allreduce          # one benchmark (repeatable, globs OK)
bash status-check.sh -s                    # node lists per status, no reasons
bash status-daily-report.sh               # CSV to reports/, with performance metrics
bash watch-rack.sh "rack01-node[1-32]"    # live view of DOWN/drained nodes
```

A node that has stopped testing:

```bash
bash trigger-debug.sh ink50-dh01-h20      # walk BCM → sbatch, name the broken link
tail results/<node>/trigger.log           # that node's own per-cycle decisions
```

A node that has been drained:

```bash
bash health-check.sh                      # every failed health check, grouped by check
sinfo -n node001 -o '%T %E'               # state and reason
bash sync-check.sh node001                # diff its health output vs the baseline
scontrol update nodename=node001 state=RESUME
```

A drain reason containing `auto-retry` is the sequencer's own — it clears it on the next retry pass, so resuming by hand only starts the next sweep sooner. Any other reason is an operator drain, and the sequencer will neither clear it nor queue work behind it.

Re-run health checks, or start a node's benchmarks over after a hardware swap:

```bash
bash node-health-refresh.sh node001
bash single-node-purge.sh node001
```

Full command reference in [docs/operations.md](docs/operations.md); retry and drain rules in [docs/sequencer.md](docs/sequencer.md).

# auto-action-trigger

Automated node bring-up and validation framework for HPC clusters managed by **Bright Cluster Manager (BCM)**. When a node boots and its device status becomes `UP`, BCM monitoring triggers fire two action scripts that run hardware health checks and sequence through Slurm benchmark jobs — draining the node in Slurm automatically on any failure.

## Prerequisites

Before deploying this framework, the following must be in place:

### The `cmods` user

A local user named `cmods` must exist on the **headnode and every compute node** in the cluster.

- All scripts assume the repo is deployed at `/home/cmods/bringup/`. The `cmods` home directory is the deployment root.
- `node_health.sh` runs as whatever user BCM invokes it as, but it `chown`s its log output to `cmods:cmods`. The `cmods` user must therefore be resolvable on the node at the time the script runs.
- `launch_job.sh` submits Slurm jobs via `su - cmods`, so `cmods` must be a valid login user with access to the Slurm environment (`/etc/profile.d/modules.sh` and the `slurm` module).
- The `cmods` user must have write access to `/home/cmods/bringup/logs/`, `/home/cmods/bringup/results/`, and `/home/cmods/bringup/reports/` on the headnode.
- If the home directory is shared via NFS or another network filesystem, compute nodes will inherit it automatically. If not, `/home/cmods/bringup/` must be accessible on each compute node (e.g., via a shared filesystem mount).

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
| `dcgmi` | `jobs/dcgm.sbatch`, `jobs/dcgm-r2.sbatch`, `jobs/dcgm-r4.sbatch` |
| `nvsm` | `jobs/nvsm.sbatch` (runs on the host, no container) |
| `nvidia-imex-ctl` | `node_health.sh` (IMEX checks, GB series only) |
| `dshbak` | `status-check.sh` |
| `rsync` | `actions/file_copy.sh` (optional) |

### Operational scripts (headnode only)

The following scripts are run manually by an operator from the headnode and do not require the `cmods` user — they only need standard Slurm CLI access and read/write access to the repo directory:

| Script | Requires |
|--------|---------|
| `status-check.sh` | `sinfo`, `dshbak`, read access to `results/` |
| `status-daily-report.sh` | read access to `results/`, write access to `reports/` |
| `node-health-refresh.sh` | write access to `logs/<node>/` |
| `sync-check.sh` | read access to `logs/` and `valid-config/` |
| `watch-rack.sh` | `sinfo` |
| `single-node-purge.sh` | write access to `results/` |
| `set-valid-default.sh` | write access to `valid-config/` |
| `pre-post/create-action-trigger.sh` | `cmsh` (BCM admin access) |
| `pre-post/delete-action-trigger.sh` | `cmsh` (BCM admin access) |

## How it works

```
Node boots → BCM device status = UP
    ├── NodeHealthTrigger → node_health.sh
    │       Compares hardware/software state against a known-good baseline.
    │       Sets node IDLE (all checks pass) or DOWN with a reason (any fail).
    │
    └── LaunchJobTrigger → launch_job.sh
            Sequences through benchmarks (dcgm → allreduce → alltoall).
            Submits the next Slurm job when the node is idle and the prior run passed.
            Drains the node if a benchmark fails or runs too long.
```

Both triggers fire continuously while the device is UP (`duringactions`), so they re-evaluate on each BCM monitoring cycle without manual intervention.

## Directory layout

```
.
├── pre-post/
│   ├── create-action-trigger.sh   # Register actions and triggers in BCM
│   └── delete-action-trigger.sh   # Remove actions and triggers from BCM
│
├── actions/
│   ├── node_health.sh             # Hardware/software health checks → Slurm node state
│   ├── launch_job.sh              # Benchmark sequencer → Slurm job submissions
│   ├── file_copy.sh               # Rsync containers to node (category-gated)
│   └── valid-node-check.sh        # BCM health-check script (category-based PASS/FAIL)
│
├── jobs/
│   ├── example.sbatch             # Annotated template for adding new benchmarks
│   ├── dcgm-r2.sbatch             # DCGM diagnostics (level 2, TTM gate)
│   ├── dcgm.sbatch                # DCGM diagnostics (level 3, Hybrid gate)
│   ├── dcgm-r4.sbatch             # DCGM diagnostics (level 4, Exhaustive gate)
│   ├── nvbandwidth.sbatch         # HBM / PCIe / NVLink bandwidth
│   ├── allreduce.sbatch           # NCCL all-reduce, NVLink scope
│   ├── alltoall.sbatch            # NCCL all-to-all, NVLink scope
│   ├── allreduce-nonvlink.sbatch  # NCCL all-reduce over HCAs (NVLink excluded)
│   ├── alltoall-nonvlink.sbatch   # NCCL all-to-all over HCAs (NVLink excluded)
│   ├── nvsm.sbatch                # NVSM stress test
│   ├── stream.sbatch              # STREAM CPU memory bandwidth
│   ├── memtester.sbatch           # DRAM integrity
│   ├── stress-ng.sbatch           # CPU / cache / mmap stress
│   ├── stressapptest.sbatch       # Extended memory integrity
│   ├── fio.sbatch                 # Local NVMe / shared storage I/O
│   ├── ethr.sbatch                # North-south management + storage NIC
│   ├── nvloom.sbatch              # MNNVL fabric health (optional/exploratory)
│   ├── mnubergemm.sbatch          # GPU burn-in (single node per the plan)
│   ├── llm-pretrain.sbatch        # Single-node LLM pre-training workload gate
│   ├── hpl.sbatch                 # HPL (Linpack), GB200 remediation-only GEMM
│   ├── cublasmatmul.sbatch        # GB300 remediation-only single-node GEMM
│   └── hpl/
│       ├── hpl1N.dat              # HPL config for 1-node runs
│       └── hpl2N.dat              # HPL config for 2-node runs
│
├── NODRAIN                        # Present = never drain on failure (delete to enable)
├── set-valid-default.sh           # Capture a validated node as the health baseline
├── node-health-refresh.sh         # Trigger a re-health-check on one or more nodes
├── single-node-purge.sh           # Clear benchmark results for a node
├── status-check.sh                # Live per-node benchmark status (all nodes)
├── status-daily-report.sh         # Generate dated CSV report with performance metrics
├── sync-check.sh                  # Diff a drained node's health output vs baseline
└── watch-rack.sh                  # Watch a nodelist for DOWN/drained nodes
```

### Single-node test coverage

`jobs/` covers the single-node (SNT) rows of the [AI Factory Testing Plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md).
Which subset runs depends on the delivery methodology for the site — see the
commented catalog above `benchmarks=` in `actions/launch_job.sh`.

| Plan row | Job | Variants |
|----------|-----|----------|
| DCGM Diagnostics `-r 2` / `-r 3` / `-r 4` | `dcgm-r2`, `dcgm`, `dcgm-r4` | TTM / Hybrid / Exhaustive |
| nvbandwidth | `nvbandwidth` | all |
| NCCL Single Node, NVLink | `allreduce`, `alltoall` | all |
| NCCL Single Node, No NVLink | `allreduce-nonvlink`, `alltoall-nonvlink` | all |
| NVSM Stress Test | `nvsm` | Hybrid, Exhaustive |
| STREAM + Memtester | `stream`, `memtester` | Exhaustive |
| stress-ng | `stress-ng` | Exhaustive |
| stressapptest | `stressapptest` | Exhaustive |
| fio | `fio` | Exhaustive |
| ethr | `ethr` | Exhaustive |
| nvloom — Single-Node Health + Burn-In | `nvloom` | Exhaustive (optional) |
| MNUberGEMM Burn-In | `mnubergemm` | Hybrid, Exhaustive |
| Single-Node LLM Pre-Training | `llm-pretrain` | all |
| HPL / cuBlasMatMul (single-node GEMM) | `hpl`, `cublasmatmul` | remediation-only |

Three single-node plan rows have no `.sbatch` file because they are not Slurm
jobs: **Inventory & BOM Verification (ClusterMinder)** and **Network Fabric
Health Check (CVT)** are externally deployed collectors with their own MOPs, and
**Pre-Flight Checks** run through `actions/node_health.sh` and the Slurm prolog
rather than as a submitted job.

Jobs outside the default list ship with placeholder site values — interface
names, the `ethr` server host, the `fio` scratch directory, and the pass
thresholds in `stream.sbatch` and `cublasmatmul.sbatch`. Set these per platform
before adding a job to the `benchmarks=` list.

### Containers

Everything in the default `benchmarks=` list runs with no image built on our
side. `dcgm*` and `nvsm` use host-installed binaries; the NCCL jobs pull the
public `docker://nvcr.io#nvidia/hpc-benchmarks:26.02` image, which enroot
fetches and caches on first use. `hpl`, `cublasmatmul`, and `stream` use the
same upstream image.

`nvbandwidth`, `nvloom`, and `mnubergemm` have no public upstream image and are
left out of the default list for that reason. See
[MAKE_CONTAINERS.md](MAKE_CONTAINERS.md) for how to build or import each one
and enable the job.

## First-time setup

### 1. Set up the BCM actions and triggers

```bash
bash pre-post/create-action-trigger.sh
```

This registers two actions (`node_health_action`, `launch_job_action`) and two triggers (`NodeHealthTrigger`, `LaunchJobTrigger`) in BCM monitoring. To remove them:

```bash
bash pre-post/delete-action-trigger.sh
```

### 2. Establish a valid-config baseline

Run the health script manually on a node that has been fully validated, then capture its output as the reference:

```bash
bash set-valid-default.sh <node_name>
# e.g. bash set-valid-default.sh node001
```

This copies `logs/<node_name>/` to `valid-config/<node_name>/` and symlinks it as `valid-config/default/`. All subsequent health checks diff against this baseline.

## Expected directory paths

Scripts assume the repo is deployed at `/home/cmods/bringup/` (the home directory of the `cmods` user — see [Prerequisites](#prerequisites)). Adjust the paths at the top of each script if deploying elsewhere.

| Path | Purpose |
|------|---------|
| `/home/cmods/bringup/logs/<node>/` | Per-node health check output files |
| `/home/cmods/bringup/valid-config/default/` | Symlink to the reference baseline node |
| `/home/cmods/bringup/results/<node>/` | Per-node benchmark result files |
| `/home/cmods/bringup/reports/` | CSV reports from `status-daily-report.sh` |
| `/home/cmods/bringup/containers/` | Container images rsync'd to nodes |

## Health checks (`node_health.sh`)

The script runs each check, writes output to `logs/<node>/<check-name>`, and diffs against the baseline. Any mismatch appends to a `reason` string. After all checks, it either sets the node `IDLE` (no failures) or `DOWN` with the accumulated reason.

| Check | What it validates |
|-------|-------------------|
| `bios` | BIOS version and settings |
| `os` | Kernel version, OS readiness |
| `kernel-params` | Kernel command-line parameters |
| `cpu-specs` | CPU architecture and topology |
| `cpu-freq` | CPU governor and per-socket frequency (must be >1800 MHz in performance mode) |
| `memory` | DIMM count and size |
| `numa-settings` | `kernel.numa_balancing=0`, THP=madvise |
| `numa` | NUMA node memory sizes |
| `nvidia-smi-ecc` | GPU ECC errors, remapped rows, power state |
| `nvlinks` | NVLink count and fabric state (72 links expected on GB/B series) |
| `nvlink-ber` | NVLink Bit Error Rate |
| `nvidia-smi-p2p-nvlink` | GPU P2P NVLink capability |
| `nvidia-smi-p2p-pcie` | GPU P2P PCIe capability |
| `nvidia-smi-cuuid` | GPU ClusterUUID (rack consistency check) |
| `ib-status` | InfiniBand port state (all up and active) |
| `ib-down` | IB link recommendation flags via mlxlink |
| `ib-link` | IB link_downed and symbol_error counters |
| `ib-pkey` | IB partition key consistency |
| `ib-firmware` | IB HCA firmware versions |
| `pcie-lnk-stat` | PCIe LnkCap vs LnkSta speed/width mismatches |
| `pcie-acs` | PCIe ACS (Access Control Services) settings |
| `pcie-mrrs` | PCIe Max Read Request Size (expected 4096) |
| `iface` | Default gateway network interface |
| `bond` | Bond interface mode, speed, and member status |
| `imex-channels` | NVIDIA IMEX channel devices (GB series) |
| `imex-profile` | IMEX configuration |
| `imex-node-config` | IMEX nodes_config.cfg checksum |
| `imex-service` | IMEX service status and ports |
| `imex-readiness` | IMEX ready state via nvidia-imex-ctl |
| `imex-status` | IMEX domain and node connection status |
| `enroot` | Enroot runtime directory writability |
| `dmesg-nv_err` | NVIDIA driver NV_ERR_* errors |
| `dmesg-trace` | Kernel call traces |
| `dmesg-hw_err` | Hardware errors |
| `dmesg-xid` | NVIDIA Xid events |
| `dmesg-knvlink` | NVLink discovery failures |
| `dmesg-ipmi_ssif` | IPMI SSIF errors |
| `dmesg-mlx5_core` | Mellanox health issue errors |

A `refresh` sentinel file in `logs/<node>/` must exist for the health script to run (prevents redundant re-checks). Use `node-health-refresh.sh` to set it.

## Benchmark sequencer (`launch_job.sh`)

The active benchmark list is controlled by the `benchmarks=` variable at the top of `actions/launch_job.sh`.

Once an hour, every benchmark in that list without a passing result is queued in listed order, and Slurm runs them back to back on the node. A job passes when every one of its runs ends in `DONE`; anything else — `FAIL`, truncated output from a crashed node, or no result at all — is queued again on the next sweep. There is no retry limit: a node keeps being re-tested until it passes or an operator intervenes.

Benchmarks support multiple runs via `totalRuns=N` in the `.sbatch` file (see `mnubergemm.sbatch` for an example with 12 runs). Result files are named `<job>.txt` (single run) or `<job>-run<N>.txt` (multiple runs). Prior failures are archived as `<job>.fail<N>.txt` and left in place as the attempt history.

### Retry and drain behaviour

The script fires on every BCM monitoring cycle, so the hourly cadence needs no cron and no second trigger — just a time gate. Retry state is derived entirely from files already on disk: the newest result file's mtime is when the last sweep ran, and the archived `.fail<N>.txt` files are the attempt history. There is no state file to keep in sync.

The node is drained **only after a full sweep** — every benchmark has run at least once and something is still not passing. A single failure mid-sweep does not drain, so the rest of the sweep still runs and one bad test does not hide the state of the others.

Drains fire only on failures that **just happened** — results newer than `DRAIN_WINDOW_MINUTES` (default: 15). Stale result files never trigger a drain, so a node you resume by hand is not immediately pulled back out of service; it takes a fresh retry sweep failing again. Keep that window above the BCM monitoring interval, or the drain is missed, and well below `RETRY_INTERVAL_HOURS`.

The drain reason carries an `auto-retry` marker, and only drains carrying that marker are ever cleared. A node drained by an operator is never auto-resumed, and nothing is queued behind their drain — otherwise the whole batch would land the moment they resumed it.

```
sweep runs → all pass            → node left idle, quick-view all DONE
sweep runs → some fail           → drain "<jobs> FAIL (auto-retry)"
             +1 hour             → resume, archive failures, re-queue them
             fails again         → drain again, repeat indefinitely
```

If a job has been running longer than `MAX_JOB_HOURS` (default: 6), the node is drained with a timeout reason. That reason carries no marker, so a stuck job stops the retry loop and waits for a human.

### Disabling drains (`NODRAIN`)

A file named `NODRAIN` in the bringup root disables every drain the sequencer would issue, including the `MAX_JOB_HOURS` timeout drain:

```bash
touch /home/cmods/bringup/NODRAIN     # stop draining on failure
rm /home/cmods/bringup/NODRAIN        # resume normal behaviour
```

Nothing else changes — benchmarks still run, results are still recorded, and failures still re-queue hourly. The node is simply never taken out of service, so failures show up in `status-check.sh` and the CSV report rather than in `sinfo`.

Useful during early bringup when you want the full picture across a rack before nodes start dropping out, or while debugging a benchmark that is failing for reasons unrelated to the hardware.

**This repo ships with `NODRAIN` present**, so drains are off out of the box. Delete it once you want failures to pull nodes from the pool. It does not clear drains that already exist — see below.

### Marking a node back to idle

Draining is one-way; the sequencer only clears its own drains, and only after the retry interval. To return a node yourself:

```bash
scontrol update nodename=node001 state=RESUME              # clears drain + reason
scontrol update nodename="node[001-018]" state=RESUME      # a whole rack
```

`RESUME` is what you want in almost every case — it clears the drain reason and lets Slurm put the node back to `idle` or `alloc` on its own. Setting `state=IDLE` directly is rejected from some states and skips that bookkeeping.

Check what a node is drained for before clearing it:

```bash
sinfo -n node001 -o '%T %E'          # state and reason
scontrol show node node001           # full detail
sinfo -R                             # every drained node with reasons
```

If the reason contains `auto-retry`, the sequencer put it there and will clear it itself on the next retry pass — resuming by hand just starts the next sweep sooner. Any other reason is an operator drain, and the sequencer will neither clear it nor queue work behind it.

`sync-check.sh <node>` diffs a drained node's health output against the baseline for each check named in the drain reason, which is usually the fastest way to see why `node_health.sh` drained it.

#### Slurm permissions

`scontrol update nodename=...` requires privilege. It works as `root`, as the `SlurmUser` (typically `slurm`), or as an account with an admin level set in the accounting database. To grant a user that access:

```bash
sacctmgr modify user name=<user> set adminlevel=Operator        # drain/resume nodes, manage jobs
sacctmgr modify user name=<user> set adminlevel=Administrator   # full control, incl. accounting
sacctmgr show user <user> withassoc format=User,AdminLevel      # verify
```

`Operator` is enough for node state changes and is the right level for anyone doing bringup. `Administrator` additionally allows modifying accounts, associations, and QOS — grant it sparingly.

The `sacctmgr modify` command itself must be run by `root`, the `SlurmUser`, or an existing `Administrator`, and requires `slurmdbd` with accounting storage configured. Without accounting enabled, admin levels do not apply and node state changes are limited to `root` and the `SlurmUser`.

## Operational scripts

### Check status across all nodes

```bash
bash status-check.sh
```

Reads `results/` and prints per-node status (`NOT_RUN`, `IN_PROGRESS`, `DONE`, `FAIL`) for each benchmark column, grouped by identical status via `dshbak`.

### Generate a CSV performance report

```bash
bash status-daily-report.sh
```

Writes `reports/report-YYYY-MM-DD_HH-MM-SS.csv` with one row per node. Completed jobs show extracted performance metrics (Gflops for HPL, busbw GB/s for allreduce/alltoall) instead of a status string.

### Re-trigger health checks

```bash
bash node-health-refresh.sh node001
bash node-health-refresh.sh "node00[1-18]"
```

### Investigate a drained node

```bash
bash sync-check.sh node001
```

Diffs the node's health check output files against the valid-config baseline for each check listed in the Slurm drain reason.

### Watch a rack for node failures

```bash
bash watch-rack.sh "rack01-node[1-32]"
```

Refreshes every 20 seconds, showing only nodes that are DOWN or drained.

### Purge benchmark results (e.g., after hardware swap)

```bash
bash single-node-purge.sh node001
```

Removes `results/node001/` so the benchmark sequence restarts from scratch.

## Adding a new benchmark

1. Copy `jobs/example.sbatch` to `jobs/<name>.sbatch`.
2. Set `job_name=<name>` and optionally `totalRuns=N`.
3. Add your workload between the job and parse sections.
4. The parse section must `echo DONE` on success or `echo FAIL` on failure as the last line.
5. Add `<name>` to the `benchmarks=` list in `actions/launch_job.sh`.

## Dependencies

- **Bright Cluster Manager** (BCM / `cmsh`) for monitoring triggers and actions
- **Slurm** for job scheduling and node state management
- Standard HPC tools: `nvidia-smi`, `ibstatus`, `mlxlink`, `lspci`, `numactl`, `dmidecode`, `dcgmi`, `nvidia-imex-ctl`
- `dshbak` for grouped output in `status-check.sh`

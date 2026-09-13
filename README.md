# auto-action-trigger

Automated node bring-up and validation framework for HPC clusters running Slurm. A `systemd --user` timer on every node runs one agent every couple of minutes, as an unprivileged automation account, which runs hardware health checks, caches container images on local disk, and sequences through Slurm benchmark jobs — draining the node in Slurm automatically on any failure. A second timer on the head node watches the heartbeat each node writes to the shared tree and re-arms any node that stops writing one.

```
head node                          every node under test
─────────────────────────          ────────────────────────────────────────────
bringup-supervisor.timer           bringup-agent.timer  → agent/node-agent.sh
  → agent/supervisor.sh                 │
      sinfo: idle or drained            ├── touch results/<node>/.heartbeat
      stat:  heartbeat stale?           ├── any job on this node? → say so, stop
      clush: install-agent.sh           │
                                        ├── file_copy.sh
                                        │     Rsyncs containers/ to NODE_CONTAINER_DIR so
                                        │     job start reads the image off local disk.
                                        │
                                        ├── node_health.sh
                                        │     Compares hardware/software state against a
                                        │     known-good baseline. Sets the node IDLE (all
                                        │     checks pass) or DOWN with a reason (any fail).
                                        │
                                        └── launch_job.sh
                                              Sequences through benchmarks (dcgmi-r1 →
                                              dcgmi-r3 → allreduce). Submits the next Slurm
                                              job when the node is idle and the prior run
                                              passed. Drains the node if a benchmark fails.
```

Nothing here is a service you start by hand and nothing runs as root: the timers re-evaluate every cycle, so a node picks up a new image or a changed setting without rebooting, and the handful of commands that genuinely need privilege go through `sudo -n`. There is no dependency on a cluster manager — this was three BCM monitoring triggers until August 2026, and a BCM head node still works exactly as before, it is simply no longer in the path.

This page covers what has to be in place, how to stand the framework up, and the commands a bringup needs day to day. Everything else is in [docs/](docs/):

`docs/` is organised by [Diátaxis](https://diataxis.fr/) — by what you are
doing, not by which script the page is about. [docs/README.md](docs/README.md)
is the compass; the four entry points are:

| If you are… | Start at |
|------|--------|
| new to this and want it working on one node | [docs/tutorials/](docs/tutorials/) — a first bringup, how the agent fires, reading the fleet through Slurm |
| trying to get something specific done | [docs/how-to/](docs/how-to/) — enabling benchmarks, pausing, managing drains, diagnosing a failure |
| looking up a setting, a flag, or what a trace line means | [docs/reference/](docs/reference/) — `SETTINGS`, the job catalog, the 38 health checks, every operator script |
| trying to understand why it works this way | [docs/explanation/](docs/explanation/) — the sequencer, derived verdicts, drain recovery, containers |

## Prerequisites

### The automation user

A local user named by `JOB_USER` — `cmods` as shipped — must exist on the **headnode and every compute node** in the cluster. It is the only place the account is named: the tree path and the llmb install derive from it, so pointing the framework at a dedicated automation account is one line in `SETTINGS` and no code change. See [docs/reference/settings.md#accounts-and-paths](docs/reference/settings.md#accounts-and-paths).

- The tree is deployed at `$BRINGUP_HOME`, which defaults to `/home/$JOB_USER/bringup/` — that home directory is the deployment root.
- Every cycle runs as `$JOB_USER` under that account's `systemd --user`, so the account needs lingering enabled (`agent/install-agent.sh` does it) and passwordless ssh from the head node.
- It needs a `sudo` rule for the handful of privileged commands the health checks and the drains use — `agent/sudoers.default` is the shipped reference. See [docs/explanation/running-unprivileged.md](docs/explanation/running-unprivileged.md).
- `launch_job.sh` submits Slurm jobs as that account directly, so it must be a valid login user with access to the Slurm environment (`/etc/profile.d/modules.sh` and the `slurm` module), and with whatever Slurm association the site requires — an `sbatch` refused for a missing association lands in `trigger.log` rather than being swallowed.
- It must have write access to `logs/` and `results/` under the deployment root on the headnode.
- If the home directory is shared via NFS or another network filesystem, compute nodes will inherit it automatically. If not, `$BRINGUP_HOME` must be accessible on each compute node (e.g., via a shared filesystem mount).

The container images do **not** have to live under that home directory: `CONTAINER_DIR` is its own setting, so they can sit on whatever bulk share the site has, and `CONTAINER_DIR_HEAD` covers the case where the headnode mounts that share at a different path than the compute nodes do. See [docs/explanation/containers.md#one-share-two-mount-points](docs/explanation/containers.md#one-share-two-mount-points).

`jobs/nvl72/nvsm.sbatch` runs only on **DGX** systems and additionally needs a passwordless sudoers grant for `$JOB_USER` on every compute node — see [docs/how-to/enable-nvsm.md](docs/how-to/enable-nvsm.md). It is the only job with either requirement, and for both reasons it is not in the default `BENCHMARKS` list.

### Required software

| Software | Used by |
|----------|---------|
| `systemd` (`systemctl --user`, `loginctl`) | `agent/install-agent.sh`, and the two timers |
| `clush` (ClusterShell), or `pdsh` | `agent/supervisor.sh` (arming nodes), and every remote command in the docs. `FANOUT_TOOL` picks; `auto` prefers clush |
| `sudo` | `node_health.sh` (7 of 38 checks), `slurm-recovery.sh` — see [docs/explanation/running-unprivileged.md](docs/explanation/running-unprivileged.md) |
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
| `clubak` (ClusterShell), or `dshbak` (pdsh) | `status-check.sh`, to group identical rows. Ships with `clush`/`pdsh` respectively, so installing either family covers both |
| `rsync` | `actions/file_copy.sh` (optional) |

### Required host settings (the NFS server)

Whichever host exports `$BRINGUP_HOME` to the compute nodes — the headnode at most sites — must not hand out NFSv4 delegations:

| Setting | Where | Why |
|---------|-------|-----|
| `fs.leases-enable = 0` | `/etc/sysctl.d/` on the NFS server, applied with `sysctl --system` | Every node polls its own `results/<node>/.slurm-view` read-only and never writes it, so NFSv4 grants a read delegation on it. The watchdog rewrites all of them every cycle, and each one has to be recalled first — about 30 seconds for a node that does not answer. Enough silent nodes and the cycle exceeds its `TimeoutStartSec` and is killed before it writes anything, which stops the whole fleet |

Check it and set it with:

```bash
cat /proc/sys/fs/leases-enable                                                  ## want 0
echo 'fs.leases-enable = 0' | sudo tee /etc/sysctl.d/90-nfsd-no-delegations.conf
sudo sysctl --system
```

It takes effect immediately and needs no remount, no client change and no reboot; delegations already granted lapse rather than being recalled. What it trades away, and the measurement that identifies the problem when it is *not* set, are in [docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations](docs/explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations).

`agent/install-agent.sh` refuses to arm the serving host until this is set, and says so rather than arming a fleet that will stall hours later. It checks nothing on a compute node — a host that mounts the tree has no delegation to grant. `ALLOW_NFS_DELEGATIONS=yes` forces the install past the refusal and downgrades it to a warning on every run. **Do not use it outside a deliberate experiment.** It changes nothing about the recalls; it only removes the one warning you would get before the fleet stops, and the stall it leads to reads as a dead watchdog rather than as a filesystem problem — which is what made this cost ten hours the first time.

For a large simultaneous container copy, bound the NFS server itself instead of
coordinating clients with shared lock files. For example, this drop-in limits
`nfs-server.service` to the equivalent of 64 fully occupied CPU cores:

```ini
# /etc/systemd/system/nfs-server.service.d/override.conf
[Service]
CPUQuota=6400%
```

Apply it during an appropriate service window:

```bash
sudo systemctl daemon-reload
sudo systemctl restart nfs-server.service
```

Choose the quota for the server. This limits CPU consumption; it does not cap
storage or network bandwidth, and the framework intentionally adds no
fleet-wide copy lock.

### Operational scripts (headnode only)

The following scripts are run manually by an operator from the headnode and do not require the `cmods` user — they only need standard Slurm CLI access and read/write access to the repo directory:

| Script | Requires |
|--------|---------|
| `status-check.sh` | `sinfo`, `clubak` or `dshbak`, read access to `results/` |
| `check_squeue.sh` | `squeue`; `-j` also uses `sinfo` and `scontrol` |
| `daily-report.sh` | `sinfo`, read access to `results/`; write access to wherever `-o` points |
| `health-check.sh` | `sinfo`, `scontrol`, read access to `logs/` and `valid-config/` |
| `health-check.sh --refresh` | write access to `logs/<node>/` |
| `trigger-debug.sh` | `sinfo`, read access to `results/`; `--ask-nodes` also needs `clush` or `pdsh` |
| `trigger-log.sh` | read access to `results/` and `logs/` |
| `next-run.sh` | `clubak` or `dshbak`, read access to `results/` and `logs/` |
| `watch-rack.sh` | `sinfo` |
| `single-node-purge.sh` | write access to `results/` |
| `kill-jobs.sh` | `squeue`, `scancel` as `JOB_USER` or root; `-p` also needs write access to `SETTINGS` |
| `set-valid-default.sh` | write access to `valid-config/` |
| `agent/install-agent.sh` | Run as `JOB_USER`; `systemctl --user`, `loginctl`, and permission to enable lingering |

Draining and resuming nodes needs Slurm privilege — see [docs/reference/layout.md](docs/reference/layout.md#slurm-permissions).

## First-time setup

### 1. Confirm sudo works, and arm the head node

Nothing here configures a node. Seven of the health checks read `dmesg`, three
walk PCIe config space, one reads `dmidecode`, and the drain path calls
`scontrol update` — all as `$JOB_USER`, all through `sudo -n`. Those rules are
the site's to deploy, via the BCM software image so they survive a reprovision;
`agent/sudoers.default` is the reference to hand to whoever owns that image, and
[docs/explanation/running-unprivileged.md](docs/explanation/running-unprivileged.md)
says what each entry is for.

Confirm it is in place before arming anything:

```bash
clush -w <node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
pdsh -R ssh -w <node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
```

Run it as `$JOB_USER`, from the head node, over a fan-out rather than a bare
`ssh` — that reproduces how the agent will run it, and the same line checks a
whole rack by widening `-w`. The authoritative check is the framework's own,
which preflights every command this check set needs and names any that are
missing:

```bash
clush -w <node> '/home/cmods/bringup/agent/node-agent.sh --explain'
pdsh -R ssh -w <node> '/home/cmods/bringup/agent/node-agent.sh --explain'
```

A missing rule does not make a check fail — it changes its output, which the
baseline diff reads as a hardware fault — so `node_health.sh` refuses to run at
all rather than judge a node without it. `trigger-debug.sh --ask-nodes` asks the
same question fleet-wide once nodes are armed.

Then, as `$JOB_USER` on the head node:

```bash
bash agent/install-agent.sh
```

It works out that this host is the head node — `slurmctld` installed and `slurmd` not — enables lingering, installs `bringup-supervisor.timer`, and starts it. Within `HEARTBEAT_STALE_MINUTES` the watchdog arms every idle node itself; nothing has to be installed node by node. It reports `ok:` or `FAILED:` per step and exits non-zero if any failed, because an arm that fails quietly is how you end up believing a node is being health-checked when it is not.

It names the role it decided and why — `slurmctld is running here` on the head node. If it gets that wrong, `--head` and `--node` override it; a head node armed as a compute node runs an agent that correctly does nothing, and leaves nobody arming the fleet.

Safe to re-run, and re-running is how a changed unit or interval is picked up. See [docs/how-to/arm-a-node.md](docs/how-to/arm-a-node.md).

### 2. Confirm the agents came up on the compute trays

Nothing is installed tray by tray. The watchdog arms every `idle` or `drained` node itself, over one `clush`, within `HEARTBEAT_STALE_MINUTES` of its heartbeat going stale — so the first check is simply to watch it happen:

```bash
tail -f /home/cmods/bringup/results/supervisor.log
```

One line per cycle whether or not it armed anything. Within a few minutes you want to see it name the trays and then stop naming them:

```
14:22:03 ARM 18 node(s) whose heartbeat is older than 10m, over clush: ink50-dh01-h02-[11-28]
14:24:05 checked 18 node(s): 18 fresh, 0 armed, 0 with work on them, 0 not answering, 0 filtered out
```

`18 fresh, 0 armed` is the answer: every tray is writing a heartbeat and none needs arming. To check it directly rather than watching:

```bash
bash trigger-log.sh                                     # section 0, fleet-wide
stat -c '%y %n' /home/cmods/bringup/results/*/.heartbeat | sort   # newest write per tray
```

Every heartbeat should be within `AGENT_INTERVAL_MINUTES` — two minutes as shipped. A tray with no `.heartbeat` at all has never been armed; one whose heartbeat has stopped has a timer that is not firing, and `results/<tray>/arm.log` holds what the watchdog heard back from it on each attempt.

To ask a tray itself:

```bash
clush -w 'ink50-dh01-h02-[11-28]' 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active bringup-agent.timer'
pdsh -R ssh -w 'ink50-dh01-h02-[11-28]' 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active bringup-agent.timer'
```

`active` on every line. `trigger-debug.sh --ask-nodes` runs that plus the lingering and sudo checks across everything it found stale, and `bash trigger-debug.sh` on its own answers the same questions from NFS for free.

Then watch a tray decide something:

```bash
tail -f /home/cmods/bringup/results/<tray>/agent.log
```

`idle: no job here -- file_copy node_health launch_job` is a working cycle. `BUSY: job(s) … running here` is a tray with work on it, which does nothing else by design. Nothing at all after a few minutes means the timer is not firing there — go back to `arm.log`. See [docs/how-to/arm-a-node.md](docs/how-to/arm-a-node.md) and [docs/tutorials/understanding-the-agent.md](docs/tutorials/understanding-the-agent.md).

### 3. Download the container images

```bash
./build_containers.sh -L     # log in to nvcr.io — once per machine, needed for the private-org images
./build_containers.sh -a arm hpc-benchmarks nvbandwidth mnubergemm
```

Run on the headnode, once per CPU architecture in the cluster. Name the images you want — there is no setting for it, because everything in `CONTAINER_DIR` is cached on every node and one place should decide. `-A` adds `nvloom`, the one image no registry publishes. Add `nemo` when you enable the LLM jobs.

`-L` is not optional for that list: `nvbandwidth` and `mnubergemm` come from a private NGC org, and without credentials they fail to download and their two jobs then fail on every node. `./build_containers.sh -l` says which images are actually present. A site that would rather not need an NGC key builds neither and drops both names from `BENCHMARKS`.

Downloading is the default and, without `-S`, the only path: an image that cannot be pulled reports why rather than starting a source build. `-L` writes `~/.config/enroot/.credentials`. See [docs/explanation/containers.md](docs/explanation/containers.md).

### 4. Establish a valid-config baseline

Run the health script manually on a node that has been fully validated, then capture its output as the reference:

```bash
bash set-valid-default.sh <node_name>
# e.g. bash set-valid-default.sh node001
```

This copies `logs/<node_name>/` to `valid-config/<node_name>/` and symlinks it as `valid-config/default/`. All subsequent health checks diff against this baseline.

It is a **copy**, deliberately, and pointing `valid-config/default` at a live `logs/<node>/` instead is the one edit to avoid here: the checks re-run on a cadence, so the baseline would follow that node's drift and the fleet would keep agreeing with it. `node_health.sh` refuses to run rather than overwrite its own baseline. See [docs/explanation/health-cadence.md#the-golden-baseline](docs/explanation/health-cadence.md#the-golden-baseline).

### 5. Make a SETTINGS file

Everything configurable lives in one file. `SETTINGS.default` ships with the framework and is read when there is no `SETTINGS`; `SETTINGS` is what a site edits and is never overwritten by an upgrade.

```bash
cp SETTINGS.default SETTINGS
```

Editing `SETTINGS.default` in place works until the next tarball drop replaces it. A `SETTINGS` only has to carry the lines you changed — anything it leaves out falls back to the shipped default. See [docs/reference/settings.md](docs/reference/settings.md).

### 6. Choose the benchmark list

The active list is `BENCHMARKS` in `SETTINGS`; which subset a site should run depends on its delivery methodology. See [docs/reference/jobs.md](docs/reference/jobs.md).

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 nvbandwidth allreduce allreduce-forcesharp \
            alltoall allreduce-nonvlink alltoall-nonvlink"
```

### 7. Decide whether to burn in

Burn-in is a second list, queued alongside the sweep, and off until you ask for it:

```bash
RUN_BURNIN=no
BURNIN="mnubergemm"
```

`mnubergemm` is 12 runs of a ~6-hour step, one job at a time, so a node is under burn-in for about three days. It is not gated on the benchmarks passing — it is ordered behind them by `#SBATCH --nice` in the job files (the dcgmi gates at 1-4, the rest of the sweep at 20, burn-in at 100000), so a benchmark retry queued mid-burn-in goes ahead of the runs still waiting rather than behind all of them. It does not interrupt the run already on the node: every job is `--exclusive`.

`MAX_JOB_HOURS` ships at `7` to clear a single burn-in run — lower it and the sequencer drains healthy nodes mid-run for a timeout. The image is downloaded by default even though the list is off, so turning it on does not mean a fleet-wide failure while the image catches up. See [docs/reference/settings.md](docs/reference/settings.md#burn-in).

### 8. Decide whether failures should drain

Both drain switches ship **off**, so no failure takes a node out of service:

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # health check mismatched the baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # benchmark sweep failed, or a job ran past MAX_JOB_HOURS
```

Turn them on once the failures being reported are real ones. Health-check drains are the riskier half — a bad baseline drains the whole cluster on the first agent cycle — so bring that one up only after `bash health-check.sh --summary` reads clean. See [docs/how-to/manage-drains.md](docs/how-to/manage-drains.md).

### 9. Decide how often health checks re-run

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
bash daily-report.sh -c -o ~/r.csv        # same rows as CSV, and keep a copy
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
bash trigger-debug.sh ink50-dh01-h20      # walk watchdog → sbatch, name the broken link
bash next-run.sh                          # the other half: when each node fires next
```

Start with `trigger-log.sh` — it reads the heartbeats and what the sequencer
already wrote down, and separates the two cases that look identical from the
outside: heartbeats stale means the timers are not firing (go to
`trigger-debug.sh`), heartbeats fresh with nothing submitted means the agent is
running and a gate is closed (the reason is already in the trace).

A node that has been drained:

```bash
bash health-check.sh                      # every failed health check, grouped by check
sinfo -n node001 -o '%T %E'               # state and reason
bash health-check.sh --diff node001       # diff its health output vs the baseline
scontrol update nodename=node001 state=RESUME
```

Stop the whole framework for a maintenance window, without disarming it — in `SETTINGS`, effective fleet-wide on the next agent cycle:

```bash
RUN_JOBS=no             # no benchmarks submitted; queued ones cancelled
RUN_HEALTH_CHECKS=no    # no health checks run; Slurm untouched
RUN_CONTAINER_COPY=no   # no new rsync into NODE_CONTAINER_DIR
RUN_ARMING=no           # the watchdog arms no node; running agents carry on
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

## Removing the framework

**Stop the watchdog first.** It re-arms any idle or drained node whose heartbeat goes stale, so disarming a rack while it is running gets the rack armed straight back within `HEARTBEAT_STALE_MINUTES`. `pause-agents.sh` does it in the right order, and writes nothing to the share:

```bash
bash pause-agents.sh          # the watchdog here, then every node timer
```

That is also the thing to run before replacing the deployment with a new drop — `rsync -av /tmp/auto-action-trigger-*/ /cluster/bringup/`, with no `--delete` and so no exclude list, because the site's own data is not in the drop to begin with. See [docs/how-to/pause-and-resume.md#replacing-the-tree](docs/how-to/pause-and-resume.md#replacing-the-tree). To remove the framework rather than stop it, carry on: on the head node, as `cmods`,

```bash
bash /home/cmods/bringup/agent/uninstall-agent.sh
```

Then empty the queue, or the last sweep runs on nodes nobody is watching:

```bash
bash kill-jobs.sh -n                      # what would be cancelled
bash kill-jobs.sh                         # cancel it
```

Then disarm the trays:

```bash
clush -w 'ink50-dh01-h02-[11-28]' '/home/cmods/bringup/agent/uninstall-agent.sh'
pdsh -R ssh -w 'ink50-dh01-h02-[11-28]' '/home/cmods/bringup/agent/uninstall-agent.sh'
```

Confirm nothing is left running, and that the heartbeats have stopped moving:

```bash
clush -w 'ink50-dh01-h02-[11-28]' 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active bringup-agent.timer'
stat -c '%y %n' /home/cmods/bringup/results/*/.heartbeat | sort | tail -3
```

`inactive` on every line, and heartbeats that stop advancing.

Finally, put back any node this framework drained. Only reasons containing `auto-retry` are ours:

```bash
sinfo -R -o '%50E %N' | grep auto-retry
scontrol update nodename=<nodes> state=RESUME
```

### What removal leaves behind, deliberately

| Left | Why |
|---|---|
| `results/`, `logs/`, `valid-config/` | The record of what this cluster did. Delete the tree when you want it gone; re-arming resumes from it |
| Lingering for `cmods` | The site's setting for the account, not this framework's — turning it off would stop anything else that account runs |
| The sudoers rules | The site deployed them, via the BCM software image. Removing them is that same path |
| `NODE_CONTAINER_DIR` on each tray (`/opt/containers` default) | A node-local cache. Deliberately persists across reboots so the fleet doesn't refill it over NFS on every power cycle — `rm -rf` it by hand if the disk is wanted back, or set `NODE_CONTAINER_DIR=/tmp/containers` for the old clears-itself behaviour |
| Drains an operator set | Never touched, in either direction |

`uninstall-agent.sh` stops and removes the timer and its unit and does nothing else. A node that is disarmed and then armed again picks the sweep up where it stopped. See [docs/how-to/arm-a-node.md#disarming-a-node](docs/how-to/arm-a-node.md#disarming-a-node).

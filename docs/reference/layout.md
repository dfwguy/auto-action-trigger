# Layout, paths and permissions

Where every file sits, where it runs from, and who has to own what. Why the
pieces fit together this way is
[explanation/architecture.md](../explanation/architecture.md).

## Directory layout

```
.
├── agent/
│   ├── cycle.sh                   # What the timer runs: decides the role, hands over to one of the two below
│   ├── node-agent.sh              # One cycle on one node: heartbeat, busy gate, the three steps
│   ├── supervisor.sh              # Head node: arm any idle/drained node whose heartbeat is stale
│   ├── install-agent.sh           # Enable lingering, install the units, start the timer
│   ├── uninstall-agent.sh         # Stop and remove them
│   ├── sudoers.default            # Shipped reference for /etc/sudoers.d/50-bringup
│   └── units/                     # One systemd --user service and timer for every host, @BRINGUP_HOME@ substituted at install
│
├── actions/
│   ├── node_health.sh             # Hardware/software health checks → Slurm node state
│   ├── launch_job.sh              # Benchmark sequencer → Slurm job submissions
│   └── file_copy.sh               # Rsync containers to /tmp on each node (silent no-op if none)
│
├── SETTINGS.default               # Shipped configuration; copy to SETTINGS to change anything
├── settings.sh                    # Loads SETTINGS, else SETTINGS.default; backfills unset keys
├── priv.sh                        # The one place a command needing root is run from a cycle that is not
├── fanout.sh                      # The one place a command is run on more than one node: clush, else pdsh
├── reason-map.sh                  # Slurm drain reason → check names (health-check.sh)
├── report-format.sh               # Node-list compression, wrapping and elision (health-check.sh, overall_report.sh)
├── health-scan.sh                 # The health verdict from logs/ against the baseline (health-check.sh, overall_report.sh)
├── slurm-snapshot.sh              # The fleet's one look at Slurm: written by the watchdog, read by every node
├── slurm-recovery.sh              # Clears drains Slurm set itself, never an operator's (both actions)
├── get-out-of-the-way.sh          # Cancels a node's job when somebody else is queued for it (supervisor.sh)
├── verdict-scan.sh                # Judges every cell of the fleet in parallel (status-check.sh, daily-report.sh)
│
├── health-checks/                 # One directory per platform; HEALTHCHECKS picks one
│   └── nvl72/                     # One file per check, NN-<check>.sh, run in numeric order
│       ├── 01-bios.sh
│       ├── ...
│       └── 38-dmesg-mlx5_core.sh
│
├── parsers/                       # One directory per platform; PARSERS picks one
│   └── nvl72/
│       └── verdict.sh             # Pass/fail rule and bandwidth floors for every job
│
├── jobs/                          # One directory per platform; JOBS picks one
│   └── nvl72/
│       ├── example.sbatch             # Annotated template for adding new benchmarks
│       ├── dcgmi-r1.sbatch            # DCGM diagnostics (level 1, quick gate)
│       ├── dcgmi-r2.sbatch            # DCGM diagnostics (level 2, TTM gate)
│       ├── dcgmi-r3.sbatch            # DCGM diagnostics (level 3, Hybrid gate)
│       ├── dcgmi-r4.sbatch            # DCGM diagnostics (level 4, Exhaustive gate)
│       ├── nvbandwidth.sbatch         # HBM / PCIe / NVLink bandwidth
│       ├── allreduce.sbatch           # NCCL all-reduce, NVLink scope
│       ├── allreduce-forcesharp.sbatch # NCCL all-reduce, NVLS/SHARP required (NCCL_ALGO=NVLS)
│       ├── alltoall.sbatch            # NCCL all-to-all, NVLink scope
│       ├── allreduce-nonvlink.sbatch  # NCCL all-reduce over HCAs (NVLink excluded)
│       ├── alltoall-nonvlink.sbatch   # NCCL all-to-all over HCAs (NVLink excluded)
│       ├── nvsm.sbatch                # NVSM stress test
│       ├── stream.sbatch              # STREAM CPU memory bandwidth
│       ├── memtester.sbatch           # DRAM integrity
│       ├── stress-ng.sbatch           # CPU / cache / mmap stress
│       ├── stressapptest.sbatch       # Extended memory integrity
│       ├── fio.sbatch                 # Local NVMe / shared storage I/O
│       ├── ethr.sbatch                # North-south management + storage NIC
│       ├── nvloom.sbatch              # MNNVL fabric health (optional/exploratory)
│       ├── mnubergemm.sbatch          # GPU burn-in (single node per the plan)
│       ├── llm-pretrain.sbatch        # Single-node LLM pre-training, 4-way DP; frozen llmb-run capture
│       ├── llm-pretrain-solo.sbatch   # 4 independent 1-GPU pre-training copies; per-GPU step times
│       ├── hpl.sbatch                 # HPL (Linpack), GB200 remediation-only GEMM
│       ├── cublasmatmul.sbatch        # GB300 remediation-only single-node GEMM
│       └── hpl/
│           ├── hpl1N.dat              # HPL config for 1-node runs
│           └── hpl2N.dat              # HPL config for 2-node runs
│
├── README.md                      # Entry point: what the framework is and how to deploy it
├── docs/                          # This directory
├── tests/                         # Offline suites; stub Slurm, need no cluster
├── .gitlab-ci.yml                 # CI: the tests, plus the conventions in CLAUDE.md
├── build_containers.sh            # Build job container images into containers/
├── build_llmb.sh                  # Install llmb-run + image + tokenizer for the LLM jobs
├── llmb_check.py                  # Resolve and report an llmb install; run by build_llmb.sh
├── set-valid-default.sh           # Capture a validated node as the health baseline
├── health-check.sh                # Cluster-wide health summary, plus --explain and --refresh
├── ib-visibility.sh               # Compare HCAs the host sees vs the container sees
├── single-node-purge.sh           # Clear benchmark results for a node
├── dmesg-archive.sh               # Save, clear and resume nodes drained on a full dmesg
├── kill-jobs.sh                   # Cancel our queued and running jobs; -p also pauses
├── check_squeue.sh                # The queue in one table; -j adds node state and reservations
├── status-check.sh                # Live per-node benchmark status (all nodes)
├── daily-report.sh                # Per-node table: slurm state, status, performance metrics
├── overall_report.sh              # Everything without a pass, with everything known about it
├── pause-agents.sh                # Stop every agent timer in the fleet, and start them again
├── trigger-debug.sh               # Walk the watchdog → sbatch chain and name the broken link
├── trigger-log.sh                 # Read what the chain wrote: trigger.log and health.log
└── watch-rack.sh                  # Watch a nodelist for DOWN/drained nodes
```

## Runtime paths

The tree is deployed at `$BRINGUP_HOME`, which defaults to
`/home/$JOB_USER/bringup` — so `/home/cmods/bringup/` as shipped. Every script
resolves its own location, the agent and its three steps included: the systemd
unit names them by absolute path with no working directory to infer one from,
but that path is inside the tree, so `${BASH_SOURCE[0]}` finds it. Deploying
elsewhere means changing `JOB_USER` (or `BRINGUP_HOME`) in `SETTINGS` and
nothing else.

They cannot read `BRINGUP_HOME` to find themselves, because that setting lives
in the file they are trying to locate. `AGENT_HOME`, `LAUNCH_JOB_HOME`,
`NODE_HEALTH_HOME` and `FILE_COPY_HOME` override the derivation; only the test
suites set them.

`agent/install-agent.sh` is the one place a path is written into something
outside the tree: it substitutes its own location for `@BRINGUP_HOME@` in the
unit files it copies into `~/.config/systemd/user/`. That is correct because it
runs *on* the host being armed, out of the deployed tree — but it is also why
running it from a git checkout arms that checkout, and why it warns when its own
location and `BRINGUP_HOME` disagree.

| Path | Purpose |
|------|---------|
| `$BRINGUP_HOME/logs/<node>/` | Per-node health check output files |
| `$BRINGUP_HOME/logs/<node>/.last-check` | When the checks last ran there and what they concluded, tab-separated. Drives the cadence — see [settings.md#health-check-cadence](settings.md#health-check-cadence) |
| `$BRINGUP_HOME/logs/<node>/refresh` | Present when a re-check has been asked for ahead of the cadence. Set by `health-check.sh --refresh`, consumed by the next cycle |
| `$BRINGUP_HOME/valid-config/default/` | Symlink to the reference baseline node |
| `$BRINGUP_HOME/results/<node>/` | Per-node benchmark result files |
| `$BRINGUP_HOME/results/<node>/.heartbeat` | Touched at the top of every agent cycle, before any gate. Empty; only its mtime is read. See [explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means](../explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means) |
| `$BRINGUP_HOME/results/<node>/.slurm-view` | What Slurm says about this node and its jobs, written every watchdog cycle and read instead of querying the controller. Tab separated, key first, sealed with an `end` line — see [explanation/the-fleet-snapshot.md#what-is-on-disk](../explanation/the-fleet-snapshot.md#what-is-on-disk) |
| `$BRINGUP_HOME/results/<node>/.yielded` | Left by the watchdog when it cancelled this node's job for a waiter, so the next cycle can say why rather than reporting it as gone. Tab separated: epoch, text. Read once and removed — see [explanation/the-fleet-snapshot.md#what-moved-to-the-head-node](../explanation/the-fleet-snapshot.md#what-moved-to-the-head-node) |
| `$BRINGUP_HOME/results/<node>/agent.log` | Per-cycle trace from `node-agent.sh`: the busy gate, the lock, which steps ran |
| `$BRINGUP_HOME/results/<node>/arm.log` | One line per arming attempt by the watchdog, and what came back. Tab separated: epoch, output. The attempt history `ARM_MAX_ATTEMPTS` is counted from |
| `$BRINGUP_HOME/results/.supervisor-owner` | Which host is arming the fleet, refreshed every watchdog cycle. Tab separated: hostname, epoch. A second host that finds this fresh stands by — see [explanation/the-agent-and-the-watchdog.md#only-one-watchdog](../explanation/the-agent-and-the-watchdog.md#only-one-watchdog) |
| `$BRINGUP_HOME/results/.supervisor-heartbeat` | Touched at the top of every watchdog cycle. Doubles as the clock every heartbeat age is measured against — see [explanation/the-agent-and-the-watchdog.md#whose-clock-decides](../explanation/the-agent-and-the-watchdog.md#whose-clock-decides) |
| `$BRINGUP_HOME/results/supervisor.log` | One line per watchdog cycle, including the ones that armed nothing |
| `$BRINGUP_HOME/results/.slurm/nodes.psv` | The fleet-wide `sinfo` the per-node views are cut from. For the head node's own tools; no compute node reads it |
| `$BRINGUP_HOME/results/.slurm/queue.psv` | The fleet-wide `squeue`, same |
| `$BRINGUP_HOME/results/.yield-check` | When the watchdog last looked for waiters, one stamp for the fleet — `GET_OUT_OF_THE_WAY_POLL_MINUTES` |
| `$BRINGUP_HOME/results/<node>/trigger.log` | Per-cycle decision trace from `launch_job.sh` |
| `$BRINGUP_HOME/results/<node>/copy.log` | Per-cycle trace from `file_copy.sh`, and where the detached copy reports what it did after the cycle that started it has ended |
| `$BRINGUP_HOME/results/<node>/health.log` | Per-cycle decision trace from `node_health.sh` |
| `$BRINGUP_HOME/results/<node>/quick-view.txt` | One line per benchmark: `DONE` / `QUEUED` |
| `$BRINGUP_HOME/results/<node>/recover.log` | One line per drain cleared. The attempt history `RECOVER_MAX_ATTEMPTS` is counted from. Tab separated: epoch, date, class, state, setter, reason, and the pre-job check that failed. See [explanation/drain-recovery.md#and-it-has-to-outlive-the-trace](../explanation/drain-recovery.md#and-it-has-to-outlive-the-trace) |
| `$BRINGUP_HOME/results/<node>/unkillable.stamp` | First-seen epoch and pid set of GPU processes that survived their step's kill. Tab separated; a changed pid set restarts the clock. See [explanation/drain-recovery.md#a-step-that-outlives-its-own-kill](../explanation/drain-recovery.md#a-step-that-outlives-its-own-kill) |
| `$BRINGUP_HOME/results/<node>/.not-a-compute-node` | Present when the host has decided it can never run a job. Holds the reason; every script that walks `results/*/` skips the directory. See [settings.md#hosts-that-are-not-compute-nodes](settings.md#hosts-that-are-not-compute-nodes) |
| `$CONTAINER_DIR` | Container images built by `build_containers.sh`. Defaults under the tree, but need not be there — see [explanation/containers.md#one-share-two-mount-points](../explanation/containers.md#one-share-two-mount-points) |
| `/tmp/containers/` (on each node) | Node-local cache of the above, rsync'd by `file_copy.sh` |

## Result-path ownership

Clearing `results/` is safe at any time:

```bash
mv results results.$(date +%F)     # or: rm -rf results
```

The cycle runs as `$JOB_USER` on each node, and the benchmarks are submitted as
that account too, so `results/` and `results/<node>` are recreated by the same
user that `sbatch --output` writes as. A cleared tree comes back correctly owned
on the next cycle and needs nothing done to it.

That was not always true. While the cycle was root's — under the BCM triggers —
a root-owned result directory meant `sbatch` returned a job id, Slurm scheduled
the job, and it died at startup with nowhere to write: the node returned to idle
with no result file, no `FAIL`, and no archive, which is indistinguishable from
never having been tested. `launch_job.sh` repaired the ownership every cycle to
prevent it.

**Nothing repairs it now**, because nothing has the privilege to. A tree with
root-owned directories left over from those years has to be handed over once,
as root:

```bash
sudo chown -R cmods:cmods /home/cmods/bringup/results /home/cmods/bringup/logs
```

`trigger-debug.sh` section 6-7 names the directories that need it. The cycle
warns rather than failing silently when it finds one it cannot write.

## Executable bits

The `755`/`644` split across the tree is deliberate and asymmetric. The table in
`CLAUDE.md` says which a given file is and why, and the `permissions` CI job
enforces it. The whole tree at once:

```bash
git ls-files -s | awk '{print $1, $4}' | sort
```

The short version: entry points a human or a systemd unit invokes directly are
`755`; sourced libraries, unit files, `.sbatch` files, health checks and host
launchers are `644`, because each is run as `bash <file>`, read by `sbatch`, or
read by systemd rather than executed. A `644` agent script installs happily and
then never runs, which is why `install-agent.sh` preflights the bit.

## Slurm permissions

`scontrol update nodename=...` requires privilege. It works as `root`, as the
`SlurmUser` (typically `slurm`), or as an account with an admin level set in the
accounting database. To grant a user that access:

```bash
sacctmgr modify user name=<user> set adminlevel=Operator        # drain/resume nodes, manage jobs
sacctmgr modify user name=<user> set adminlevel=Administrator   # full control, incl. accounting
sacctmgr show user <user> withassoc format=User,AdminLevel      # verify
```

`Operator` is enough for node state changes and is the right level for anyone
doing bringup. `Administrator` additionally allows modifying accounts,
associations, and QOS — grant it sparingly.

The `sacctmgr modify` command itself must be run by `root`, the `SlurmUser`, or
an existing `Administrator`, and requires `slurmdbd` with accounting storage
configured. Without accounting enabled, admin levels do not apply and node state
changes are limited to `root` and the `SlurmUser`.

## What CI gates on

`.gitlab-ci.yml` runs the checks listed under "Before committing" in `CLAUDE.md`,
and it is the last gate before a change reaches a cluster; there is no staging
deployment behind it. Nothing in the pipeline talks to Slurm, BCM or a GPU — the
suites stub those on `PATH` — so a job that needs cluster access does not belong
there, because it could only be faked. `systemd`, `loginctl` and `sudo` are
stubbed the same way.

The `lint` stage runs `shellcheck -f gcc -S warning` over every tracked `*.sh`
and `*.sbatch`, `bash -n` over the same set, the `permissions` job, and
`layout-doc`, which fails if a top-level script is not named in the tree
listing above. `severity=warning` is the gate, not the ceiling: the info- and
style-level findings below it are largely deliberate here.

The `test` stage runs the suites — `tests/verdict-test.sh`,
`tests/health-runner-test.sh`, `tests/recover-test.sh`, `tests/inflight-test.sh`,
`tests/yield-test.sh`, `tests/help-text-test.sh`, `tests/scan-cache-test.sh`,
`tests/node-queries-test.sh`,
`tests/llmb-check-test.sh`, `tests/exclude-test.sh`, `tests/report-format-test.sh`,
`tests/health-scan-test.sh`, `tests/health-report-test.sh`,
`tests/doc-links-test.sh` — as one job each, so a failure names the gate that broke without anyone opening
a log.

Seven of those exist for couplings that fail *without saying so*, which is why
they are gates rather than review items:

- `scan-cache` — break the cache key and every report still prints, still looks
  right, and is wrong about nodes whose answer has changed. See
  [explanation/verdicts-and-the-cache.md](../explanation/verdicts-and-the-cache.md).
- `help-text` — eight scripts print `--help` from their own header through a
  hardcoded `sed -n '2,NNp'`, which makes comment length a runtime property.
  Each carries a sentinel comment on the line after its range, and the suite
  fails when the two stop agreeing. See [scripts.md](scripts.md).
- `inflight` — the gate that decides whether a node already has a job out. It
  is answered from files and from `scontrol listjobs`, so a wrong answer is
  silent and self-consistent: the node reports a healthy idle cycle while
  holding two jobs, or none. See
  [explanation/sequencing.md#a-missing-result-file-is-not-a-finished-job](../explanation/sequencing.md#a-missing-result-file-is-not-a-finished-job).
- `yield` — the only code in the tree that cancels a running job. Every case
  that must not cancel asserts that `scancel` was never called. See
  [explanation/sequencing.md#getting-out-of-the-way](../explanation/sequencing.md#getting-out-of-the-way).
- `exclude` — the gate that keeps a host which is not a compute node out of the
  sweep and the reports. Both directions are silent: a false positive retires a
  real node and it reports nothing ever again, a false negative is the head node
  in every report. See
  [explanation/sequencing.md#a-host-that-is-not-a-compute-node](../explanation/sequencing.md#a-host-that-is-not-a-compute-node).
- `report-format` — `wrap_list` decides where a node list breaks, and half a
  `[14,29,34]` range is a string neither `scontrol` nor `clush -w` will take
  while looking exactly like a whole one. The suite keeps the bash
  implementation equivalent to the awk it replaced for speed.
- `doc-links` — the comment convention puts reasoning in `docs/` and leaves a
  one-line pointer in the code, which makes several hundred anchors load-bearing
  and unrendered: retitle a heading and the pointer still resolves, to the top
  of the page.

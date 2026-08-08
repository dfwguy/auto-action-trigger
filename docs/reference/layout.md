# Layout, paths and permissions

Where every file sits, where it runs from, and who has to own what. Why the
pieces fit together this way is
[explanation/architecture.md](../explanation/architecture.md).

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
│   ├── file_copy.sh               # Rsync containers to /tmp on each node (silent no-op if none)
│   └── valid-node-check.sh        # BCM health-check script (first-run-since-boot PASS/FAIL)
│
├── SETTINGS.default               # Shipped configuration; copy to SETTINGS to change anything
├── settings.sh                    # Loads SETTINGS, else SETTINGS.default; backfills unset keys
├── reason-map.sh                  # Slurm drain reason → check names (health-check.sh)
├── report-format.sh               # Node-list compression, wrapping and elision (health-check.sh, overall_report.sh)
├── health-scan.sh                 # The health verdict from logs/ against the baseline (health-check.sh, overall_report.sh)
├── slurm-recovery.sh              # Clears drains Slurm set itself, never an operator's (both actions)
├── get-out-of-the-way.sh          # Cancels this node's own job when somebody else is queued for it (launch_job.sh)
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
│       ├── llm-pretrain.sh            # Single-node LLM pre-training; host-launched via llmb-run
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
├── kill-jobs.sh                   # Cancel our queued and running jobs; -p also pauses
├── check_squeue.sh                # The queue in one table; -j adds node state and reservations
├── status-check.sh                # Live per-node benchmark status (all nodes)
├── daily-report.sh                # Per-node table: slurm state, status, performance metrics
├── overall_report.sh              # Everything without a pass, with everything known about it
├── trigger-debug.sh               # Walk the BCM → sbatch chain and name the broken link
├── trigger-log.sh                 # Read what the chain wrote: trigger.log and health.log
└── watch-rack.sh                  # Watch a nodelist for DOWN/drained nodes
```

## Runtime paths

Scripts assume the repo is deployed at `/home/cmods/bringup/` — the home
directory of the `cmods` user. The two BCM actions carry that path literally,
because BCM invokes them with no working directory to infer one from; every
other script resolves its own location. Deploying elsewhere means editing
`home=` in `actions/node_health.sh` and `actions/launch_job.sh`, and
`BRINGUP_HOME` in `SETTINGS`.

`pre-post/create-action-trigger.sh` is the exception to "resolves its own
location": it reads `BRINGUP_HOME` and registers *that* path with BCM, not the
path it was run from. Registering its own location would be wrong — run from a
git checkout it would point every node at a directory that exists only on the
head node, and the actions would fail on every node at once with no local
symptom. Because of that indirection it also preflights the deployed scripts,
not the checked-out ones.

| Path | Purpose |
|------|---------|
| `/home/cmods/bringup/logs/<node>/` | Per-node health check output files |
| `/home/cmods/bringup/logs/<node>/.last-check` | When the checks last ran there and what they concluded, tab-separated. Drives the cadence — see [settings.md#health-check-cadence](settings.md#health-check-cadence) |
| `/home/cmods/bringup/logs/<node>/refresh` | Present when a re-check has been asked for ahead of the cadence. Set by `health-check.sh --refresh`, consumed by the next cycle |
| `/home/cmods/bringup/valid-config/default/` | Symlink to the reference baseline node |
| `/home/cmods/bringup/results/<node>/` | Per-node benchmark result files |
| `/home/cmods/bringup/results/<node>/trigger.log` | Per-cycle decision trace from `launch_job.sh` |
| `/home/cmods/bringup/results/<node>/health.log` | Per-cycle decision trace from `node_health.sh` |
| `/home/cmods/bringup/results/<node>/quick-view.txt` | One line per benchmark: `DONE` / `QUEUED` |
| `/home/cmods/bringup/results/<node>/.not-a-compute-node` | Present when the host has decided it can never run a job. Holds the reason; every script that walks `results/*/` skips the directory. See [settings.md#hosts-that-are-not-compute-nodes](settings.md#hosts-that-are-not-compute-nodes) |
| `/home/cmods/bringup/reports/` | Where `daily-report.sh -o` reports are kept by convention |
| `/home/cmods/bringup/containers/` | Container images built by `build_containers.sh` |
| `/tmp/containers/` (on each node) | Node-local cache of the above, rsync'd by `file_copy.sh` |

## Result-path ownership

Clearing `results/` is safe at any time:

```bash
mv results results.$(date +%F)     # or: rm -rf results
```

The sequencer runs as root on each node (BCM actions do), so root is what
recreates `results/` and `results/<node>` on the next monitoring cycle — but the
benchmarks are submitted as `cmods`, and `sbatch --output` writes as that user.
A root-owned result directory means `sbatch` returns a job id, Slurm schedules
the job, and it dies at startup with nowhere to write: the node returns to idle
with no result file, no `FAIL`, and no archive, which is indistinguishable from
never having been tested.

`launch_job.sh` therefore re-checks ownership of both directories on every cycle
and hands them back to `cmods`, so a cleared tree repairs itself. To fix an
existing tree immediately rather than waiting for a cycle:

```bash
chown -R cmods:cmods /home/cmods/bringup/results
```

## Executable bits

The `755`/`644` split across the tree is deliberate and asymmetric. The table in
`CLAUDE.md` says which a given file is and why, and the `permissions` CI job
enforces it. The whole tree at once:

```bash
git ls-files -s | awk '{print $1, $4}' | sort
```

The short version: entry points a human or BCM invokes directly are `755`;
sourced libraries, `.sbatch` files, health checks and host launchers are `644`,
because each is run as `bash <file>` or read by `sbatch` rather than executed.
A `644` action registers with BCM fine and silently runs nothing.

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
there, because it could only be faked.

The `lint` stage runs `shellcheck -f gcc -S warning` over every tracked `*.sh`
and `*.sbatch`, `bash -n` over the same set, the `permissions` job, and
`layout-doc`, which fails if a top-level script is not named in the tree
listing above. `severity=warning` is the gate, not the ceiling: the info- and
style-level findings below it are largely deliberate here.

The `test` stage runs the suites — `tests/verdict-test.sh`,
`tests/health-runner-test.sh`, `tests/recover-test.sh`, `tests/inflight-test.sh`,
`tests/yield-test.sh`, `tests/help-text-test.sh`, `tests/scan-cache-test.sh`,
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
  `[14,29,34]` range is a string neither `scontrol` nor `pdsh -w` will take
  while looking exactly like a whole one. The suite keeps the bash
  implementation equivalent to the awk it replaced for speed.
- `doc-links` — the comment convention puts reasoning in `docs/` and leaves a
  one-line pointer in the code, which makes several hundred anchors load-bearing
  and unrendered: retitle a heading and the pointer still resolves, to the top
  of the page.

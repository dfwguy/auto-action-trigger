# Architecture and layout

Three BCM monitoring triggers fire while a node's device status is `UP`
(`duringactions`), so each one re-evaluates on every monitoring cycle without
manual intervention. Every gate in every script can end a cycle with a plain
`exit 0` — most cycles have nothing to do.

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

Because a quiet cycle and a broken chain look identical from outside, each node
keeps a running trace at `results/<node>/trigger.log`, one line per cycle
recording what it did or why it stopped. `trigger-debug.sh` reads those traces
across the cluster and names the broken link.

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
├── reason-map.sh                  # Slurm drain reason → check names (health-check.sh, sync-check.sh)
├── slurm-recovery.sh              # Clears drains Slurm set itself, never an operator's (both actions)
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
│       ├── dcgm-r2.sbatch             # DCGM diagnostics (level 2, TTM gate)
│       ├── dcgm.sbatch                # DCGM diagnostics (level 3, Hybrid gate)
│       ├── dcgm-r4.sbatch             # DCGM diagnostics (level 4, Exhaustive gate)
│       ├── nvbandwidth.sbatch         # HBM / PCIe / NVLink bandwidth
│       ├── allreduce.sbatch           # NCCL all-reduce, NVLink scope
│       ├── allreduce-nosharp.sbatch   # NCCL all-reduce, NVLink scope, NVLS/SHARP off
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
│       ├── llm-pretrain.sbatch        # Single-node LLM pre-training workload gate
│       ├── hpl.sbatch                 # HPL (Linpack), GB200 remediation-only GEMM
│       ├── cublasmatmul.sbatch        # GB300 remediation-only single-node GEMM
│       └── hpl/
│           ├── hpl1N.dat              # HPL config for 1-node runs
│           └── hpl2N.dat              # HPL config for 2-node runs
│
├── docs/                          # This directory
├── tests/                         # Offline suites; stub Slurm, need no cluster
├── .gitlab-ci.yml                 # CI: the tests, plus the conventions in CLAUDE.md
├── build_containers.sh            # Build job container images into containers/
├── set-valid-default.sh           # Capture a validated node as the health baseline
├── health-check.sh                # Cluster-wide health summary: who is drained and why
├── node-health-refresh.sh         # Trigger a re-health-check on one or more nodes
├── ib-visibility.sh               # Compare HCAs the host sees vs the container sees
├── single-node-purge.sh           # Clear benchmark results for a node
├── status-check.sh                # Live per-node benchmark status (all nodes)
├── daily-report.sh                # Per-node table: slurm state, status, performance metrics
├── sync-check.sh                  # Diff a drained node's health output vs baseline
├── trigger-debug.sh               # Walk the BCM → sbatch chain and name the broken link
├── trigger-log.sh                 # Read what the chain wrote: trigger.log across the cluster
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
| `/home/cmods/bringup/valid-config/default/` | Symlink to the reference baseline node |
| `/home/cmods/bringup/results/<node>/` | Per-node benchmark result files |
| `/home/cmods/bringup/results/<node>/trigger.log` | Per-cycle decision trace from `launch_job.sh` |
| `/home/cmods/bringup/results/<node>/quick-view.txt` | One line per benchmark: `DONE` / `QUEUED` |
| `/home/cmods/bringup/reports/` | Where `daily-report.sh -o` reports are kept by convention |
| `/home/cmods/bringup/containers/` | Container images built by `build_containers.sh` |
| `/tmp/containers/` (on each node) | Node-local cache of the above, rsync'd by `file_copy.sh` |

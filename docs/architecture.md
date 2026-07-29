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
recording what it did or why it stopped. `trigger-log.sh` reads those traces
across the cluster; `trigger-debug.sh` walks the configuration behind them when
the traces have gone stale.

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
│       ├── dcgm-r2.sbatch             # DCGM diagnostics (level 2, TTM gate)
│       ├── dcgm.sbatch                # DCGM diagnostics (level 3, Hybrid gate)
│       ├── dcgm-r4.sbatch             # DCGM diagnostics (level 4, Exhaustive gate)
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
│       ├── llm-pretrain.sbatch        # Single-node LLM pre-training workload gate
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

## Registering with BCM

`pre-post/create-action-trigger.sh` registers six objects: three monitoring
actions — `node_health_action`, `file_copy_action`, `launch_job_action` — and
one trigger apiece, `NodeHealthTrigger`, `FileCopyTrigger` and
`LaunchJobTrigger`. `pre-post/delete-action-trigger.sh` removes the same six.
cmsh has no upsert, so creation removes each object before adding it; that
makes the script safe to re-run, and it is why the removals are silent — on a
first run there is nothing to remove. The adds are not silent. A registration
that fails quietly is how you end up believing a node is being health-checked
when it is not.

An action is a path plus execution settings. All three run with `runon node`
and `nodeenvironment yes`, so BCM executes the script on the node itself, out
of the NFS-exported tree, with no working directory to infer anything from —
hence the absolute `BRINGUP_HOME` path described under [Runtime
paths](#runtime-paths). The timeout is `2m` on all three because `2m` is BCM's
hard maximum; anything larger is rejected outright. The first sync of a
container image is multi-gigabyte over NFS and cannot finish inside that, which
is why `file_copy.sh` detaches its rsync and returns immediately rather than
being killed mid-transfer on every monitoring cycle.

Each trigger attaches its action with `duringactions`, which re-fires on every
monitoring cycle while the device is `UP`. `enteractions` fires only on the
transition into `UP`, so a node that was already up would never pick up a newly
built container image until it rebooted.

Because BCM runs an action by executing the registered path, the exec bit is
part of the contract: a `644` action registers fine, reports success and
silently runs nothing. The exec bit is also easy to lose in transit — a tarball
unpacked through a Windows-mounted path, an `scp` of a single file, an editor
that rewrites rather than edits. So the script preflights the three action
scripts, restores the bit where it can, and refuses to register anything while
one is missing or still not runnable. The wider `755`/`644` split across the
tree is deliberate and asymmetric; the table in `CLAUDE.md` says which a given
file is and why, and the `permissions` CI job enforces it.

## Driving cmsh

Two things about `cmsh` shape every script that touches it.

It exits `0` even when an individual `set` inside the `-c` string was rejected.
It reports the problem on stdout and carries on to the commit, so the exit
status is useless and the output has to be inspected instead — which is what
`cm_run` in `pre-post/create-action-trigger.sh` does, grepping the combined
output for the phrasings BCM uses to refuse. Getting this wrong once already
produced a trigger with no actions attached that still reported success: the
object exists, so nothing looks broken until you notice nothing runs.

Read trigger state with `get <property>`, never by parsing `show`. The column
padding and property names in `show` output drift between BCM releases, so a
parser written against one release quietly matches nothing on the next — the
same silent-empty-result failure the framework is written against.

## What CI gates on

`.gitlab-ci.yml` runs the checks listed under "Before committing" in
`CLAUDE.md`, and it is the last gate before a change reaches a cluster; there
is no staging deployment behind it. Nothing in the pipeline talks to Slurm, BCM
or a GPU — the suites stub those on `PATH` — so a job that needs cluster access
does not belong there, because it could only be faked.

The `lint` stage runs `shellcheck -f gcc -S warning` over every tracked `*.sh`
and `*.sbatch`, `bash -n` over the same set, the `permissions` job described
above, and `architecture-doc`, which fails if a top-level script is not named
in this file's tree listing. `severity=warning` is the gate, not the ceiling:
the info- and style-level findings below it are largely deliberate here. The
`test` stage runs the five suites — `tests/verdict-test.sh`,
`tests/health-runner-test.sh`, `tests/recover-test.sh`, `tests/help-text-test.sh`,
`tests/scan-cache-test.sh` — as one job each, so a failure names the gate that
broke without anyone opening a log.

`scan-cache` is there for the same reason `help-text` is: a coupling that fails
without saying so. The reports cache verdicts under `results/.result_cache.*`,
and the thing that makes that legitimate is that the key covers the gate as well
as each result file's size and mtime — edit a floor and the fleet is re-judged.
Break that and every report still prints, still looks right, and is wrong about
nodes whose answer has changed. The suite asserts the invalidations one at a
time, including the two that no file change can signal: a node with a job on it
now, and a node whose job has just ended.

`help-text` is there for a coupling the rest of the tree does not have.
`status-check.sh`, `health-check.sh`, `daily-report.sh`, `sync-check.sh` and
`trigger-log.sh` implement `--help` by printing their own header comment through
a hardcoded `sed -n '2,NNp'`, which makes comment length a runtime property of
five operator scripts. Editing a comment is the one change everybody treats as
free, so without a gate a cleanup that shortens a header truncates `--help`
silently and passes review as "comments only" — because it is. Each of the five
carries a sentinel comment on the line after its range, and the suite fails when
the two stop agreeing.

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

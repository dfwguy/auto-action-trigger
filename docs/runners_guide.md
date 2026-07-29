# Runner's guide

For a field engineer standing up a new site. It covers where the work goes once
it runs, and how to look at it. It does not cover installation — that is
[First-time setup](../README.md#first-time-setup) in the root README, and this
guide assumes you have been through it.

The question this answers is the one that comes after "it's running": *where
did the results go, and how do I read them?*

## The shape of the thing

Nothing here is a service you start. BCM runs three actions on every node on
every monitoring cycle, and each one leaves a file behind:

| Action | Runs | Leaves behind |
|--------|------|---------------|
| `node_health_action` | `actions/node_health.sh` | `logs/<node>/<check>`, one file per health check |
| `file_copy_action` | `actions/file_copy.sh` | container images under `/tmp/containers` on the node |
| `launch_job_action` | `actions/launch_job.sh` | `results/<node>/*.txt`, plus `trigger.log` and `quick-view.txt` |

They are registered by `pre-post/create-action-trigger.sh` — see
[architecture.md](architecture.md#registering-with-bcm). All three fire
`duringactions`, meaning every cycle while the node is `UP`, so the system is a
loop that never finishes rather than a run that completes. A node that has
passed everything simply stops being given new work, and says so in its trace.

The sweep is serialized by every job asking for the whole node: one benchmark
at a time per node, all nodes in parallel. See
[sequencer.md](sequencer.md) for the ordering rules.

## Where it all lands

Everything is under the deployment root, `/home/cmods/bringup/`, exported over
NFS so the same paths mean the same thing from the head node and from every
compute node:

```
/home/cmods/bringup/
├── results/<node>/           ← benchmark output, one file per job
│   ├── allreduce.txt              a job with totalRuns=1
│   ├── dcgm-run1.txt              a job with totalRuns>1, one file per run
│   ├── dcgm-run2.txt
│   ├── allreduce.fail1.txt        an attempt that was rejected, archived
│   ├── allreduce.prev1.txt        a passing attempt that --all re-ran
│   ├── quick-view.txt             this node's current state, one screen
│   └── trigger.log                every decision the sequencer made, appended
├── logs/<node>/              ← health-check output, one file per check
│   ├── bios, os, nvlinks, ib-status, …      38 of them
│   └── refresh                    sentinel: present means "re-run the checks"
├── valid-config/default →    ← symlink to the logs/<node> of your golden node
├── containers/               ← images built by build_containers.sh
└── reports/                  ← wherever you point daily-report.sh -o
```

Three things about this layout are worth knowing on day one.

**The result file is the raw output of the job, not a verdict.** `sbatch
--output` points straight at it. Whether the contents are any good is decided
every time something reads the file, by `parsers/$PARSERS/verdict.sh` — never
written down. That is why tightening a threshold re-judges results already on
disk, and why you will not find the word `DONE` stored anywhere. See
[benchmarks.md](benchmarks.md#where-a-pass-is-decided).

**Archives are the attempt history.** `.fail<N>.txt` is an attempt the gate
rejected; `.prev<N>.txt` is a passing attempt that `launch_job.sh --all` moved
aside to re-run. The two suffixes are distinct because a re-run of a pass is not
a failure, and `status-check.sh` counts them differently.

**`results/` is disposable.** Clearing it is safe at any time and the tree
repairs itself on the next cycle — but ownership matters, and
[sequencer.md](sequencer.md#result-path-ownership) explains the failure mode
where a root-owned `results/` makes every job die silently at startup.

## Reading it: four tools, in order

Run them in this order. Each answers a question the one before it raises.

### 1. `status-check.sh` — what is the state of the fleet?

```bash
bash status-check.sh                    # every node, every benchmark
bash status-check.sh ink50-dh01-h20      # one rack (bare prefix, * is implied)
bash status-check.sh -t allreduce        # one benchmark across the fleet
bash status-check.sh -s                  # node lists per status, for pasting
```

One line per node per benchmark column, grouped by identical status so a rack
behaving the same way is one block, not 18 lines. Six statuses:

| Status | Meaning |
|--------|---------|
| `DONE` | the gate accepted the result |
| `FAIL` | the job said it could not run, **or** it ran and the gate rejected it |
| `INCOMPLETE` | no end marker and nothing on the node — it died mid-run |
| `RETRY` | the last attempt was archived and a retry is queued |
| `NOT_RUN` | never attempted |
| `RUNNING` | executing right now; nothing to judge yet |

`-s` collapses this to one compressed node list per status, disjoint, each node
under the worst status it holds — built for pasting into `pdsh -w` or
`scontrol`. Full detail in
[operations.md](operations.md#status-and-reporting).

### 2. `daily-report.sh` — what are the numbers?

```bash
bash daily-report.sh
bash daily-report.sh -c -o reports/report-$(date '+%F').csv
```

One row per node. The first column after the node name is its Slurm state, so a
row of `NOT_RUN` can be read against a node that was drained all week rather
than guessed at. Cells hold **a number where the job produced one** — GB/s for
the NCCL jobs, Gflops for HPL — and a status word only when there was no number
to print.

The number in a cell is the same figure the pass/fail floor is stated against
(out-of-place busbw at the largest message size), so you can compare a cell to a
floor in `parsers/nvl72/verdict.sh` directly. That is the whole point of the
column, and it is what makes "41 GB/s" and "2.2 GB/s" — both failures of the
same 43 GB/s floor — legible as *a slow fabric* and *a socket fallback*.

The cell does not tell you whether it passed. The `job (pass/fail)` block at the
bottom does.

### 3. `health-check.sh` — what is failing that is not a benchmark?

```bash
bash health-check.sh
bash health-check.sh --summary
bash sync-check.sh <node>              # why was this node drained?
```

Groups nodes by the *set* of checks they failed, because nodes failing the same
checks share one cause and one fix — so each group is one incident however many
nodes are in it. `sync-check.sh <node>` then diffs that one node against the
baseline for each check named in its drain reason, which is usually the fastest
route from "drained" to "why". One node per group is enough.

If it opens with `WARNING: no baseline`, stop and fix that first — nothing under
it is real. See [health-checks.md](health-checks.md#the-baseline-is-cluster-local).

### 4. `trigger-log.sh` — why is nothing happening?

```bash
bash trigger-log.sh
```

Reads `results/<node>/trigger.log` across the fleet. **Run this before
`trigger-debug.sh`**, always. Every gate in the sequencer writes down why it
stopped, so fresh traces mean the chain is intact *by definition* and a gate is
simply closed — and the gate named itself. Only when the traces are stale is the
chain itself in question, and that is what `trigger-debug.sh` is for.

The newest `EXIT:` line in a node's log is the reason nothing is happening. Every
line it can write is tabulated in
[sequencer.md](sequencer.md#every-line-the-trace-can-write).

Per node, `results/<node>/quick-view.txt` is the same state on one screen.

## Running something by hand

The sequencer submits on an hourly cadence. To not wait:

```bash
bash actions/launch_job.sh --explain          # print what it would do, submit nothing
bash actions/launch_job.sh --force            # bypass the hourly gate
bash actions/launch_job.sh --force --all      # re-run passing jobs too
```

`--explain` is the safe first move: it prints the `sbatch` command it would run
and touches nothing. A forced run writes a `MANUAL:` line into the trace, so an
hour of off-cadence results does not later read as the sequencer misbehaving —
and any gate `--force` does *not* override says so on its own line.

Note what `--force` cannot do: `PAUSE_JOBS` is a site switch, not a timing gate,
and a drain that is not ours stays. Both say so in the trace.

To submit one benchmark yourself, bypassing the sequencer entirely:

```bash
sbatch -w <node> jobs/nvl72/allreduce.sbatch
```

The job file carries its own `--nice`, walltime and allocation header, so a
hand-submitted job queues at the same priority and asks for the same resources
as one the sequencer sends. That is deliberate — see
[benchmarks.md](benchmarks.md#queue-priority).

For the health side, checks only re-run when a `refresh` sentinel exists:

```bash
bash node-health-refresh.sh <nodes>
```

## What a good site looks like

In rough order, the first day at a new site:

1. **`health-check.sh` is clean, or its groups are understood.** Health checks
   gate everything downstream — a node with the wrong BIOS or a dead HCA will
   fail benchmarks for reasons that have nothing to do with the benchmark. Get
   the baseline right first.
2. **`status-check.sh` shows columns filling in**, not a wall of `NOT_RUN`. A
   wall of `NOT_RUN` with no trace activity is a chain problem; go to
   `trigger-log.sh`.
3. **`daily-report.sh` numbers cluster tightly.** The spread across nominally
   identical nodes matters more than any single value. A fleet where every node
   lands in the same narrow band is healthy even if you have not yet confirmed
   the band is right; a fleet scattered across a 3× range has something wrong
   regardless of how good the best node looks.
4. **The outliers are few and named.** A handful of nodes below a floor is a
   hardware finding. *Every* node below a floor is a floor that is wrong, or a
   configuration that is wrong for this platform — see
   [troubleshooting_the_system.md](troubleshooting_the_system.md).

Before trusting a gate at a new site, check whether it has ever been run against
real output from this platform. Coverage is uneven and
[benchmarks.md](benchmarks.md#where-a-pass-is-decided) lists which jobs have
captured fixtures and which do not. When a job is first enabled here, capture
its result file as a fixture.

## Where to go next

| You want | Page |
|----------|------|
| What each benchmark actually measures | [benchmarks.md](benchmarks.md#what-each-job-exercises) |
| Every operator command in full | [operations.md](operations.md) |
| Why a node was drained, and by what | [health-checks.md](health-checks.md) |
| Sweep order, retries, drain rules | [sequencer.md](sequencer.md) |
| Reading a failure back to a device | [troubleshooting_the_system.md](troubleshooting_the_system.md) |
| Every setting and switch | [settings.md](settings.md) |

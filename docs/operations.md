# Operator reference

Everything here runs from the headnode and is safe to run while the triggers are
live. For the common day-to-day commands see the
[Operating a bringup](../README.md#operating-a-bringup) section of the README —
this page is the full set.

## Status and reporting

```bash
bash status-check.sh                      # every node
bash status-check.sh ink50-dh01-h20        # one rack (bare prefix)
bash status-check.sh -t allreduce          # one benchmark, every run of it
bash status-check.sh -t 'allreduce*' -t dcgm ink50-dh01-h20
bash status-check.sh -s                    # node lists per status, no reasons
bash status-check.sh -s -t allreduce       # ...judged on allreduce alone
```

`-t` is repeatable and matched as written -- no `*` is appended the way it is
for the node pattern, because benchmark names are prefixes of each other and
`-t allreduce` would otherwise drag in `allreduce-nonvlink`. It matches either
the job name (`-t allreduce` → every run) or a full column (`-t allreduce-run2`
→ that run). A pattern matching no active benchmark exits 1 and lists what is
active, rather than printing an empty report that reads like a clean cluster.

`-s` replaces the per-column report with one compressed node list per status
(FAIL / INCOMPLETE / RETRY / NOT_RUN / DONE), reasons dropped, for pasting into
`scancel`, `pdsh -w` or `scontrol`:

```
SUMMARY — judged on: allreduce

FAIL — 2 nodes (ran and was rejected by the current gate)
ink50-dh01-h20-[03,17]
```

Every node appears in exactly one list, under the worst status it holds across
the selected tests (FAIL > INCOMPLETE > RETRY > NOT_RUN > DONE), so the lists
are disjoint and a node cannot be acted on twice. DONE there means *every*
selected test passes, not that some did. The header names the tests the roll-up
covers, because a `-t`-scoped list that does not say so is one paste away from
draining nodes over a test they were never judged on.

Reads `results/` and prints per-node status for each benchmark column, grouped
by identical status via `dshbak`. Verdicts are derived from the log by
`verdict.sh` on every read, so tightening a gate re-judges results already on
disk:

| Status | Meaning |
| --- | --- |
| `DONE` | the gate accepted the result |
| `FAIL` | the job reported it could not run, or the gate rejected it |
| `INCOMPLETE` | no end marker and no job on the node -- it died before finishing (crash, walltime, OOM) |
| `RETRY` | the last attempt was archived and a retry is queued; the reason shown is why that attempt was rejected — or, after `launch_job.sh --all` archived a passing result as `.prev<N>.txt`, that the re-run was asked for |
| `NOT_RUN` | no attempt has ever been made |
| `RUNNING` | a benchmark is executing on the node right now; nothing to judge until it writes its end marker |

Columns for `BURNIN` jobs appear only while `RUN_BURNIN` is on, so an unused
burn-in list does not leave a permanent `NOT_RUN` column that reads like work
outstanding. Per node, `results/<node>/quick-view.txt` carries the state
directly: `BURN-IN OFF` when the switch is off — which is what keeps a burn-in
that never ran from being misread as one that passed — and `IN QUEUE` for
anything submitted and not yet judged.

`RUNNING` is not written by `verdict.sh`, which sees only the result file and
reports a marker-less one as `INCOMPLETE`. That is right for `launch_job.sh`,
which judges a node only after `squeue` says nothing is queued or running on
it. This script has no such guard -- `sbatch --output` points at the result
file, so a benchmark that is mid-run is a partial file with no marker. It
resolves the ambiguity with one cluster-wide `squeue`, matching the
`bringup-<node>` and `burnin-<node>` job names, and reclassifies the column
that live job is writing. Without `squeue` on `PATH` it says so on stderr and both states report
as `INCOMPLETE`.

`RETRY` and `NOT_RUN` used to be one status, which produced the contradictory
line `NOT_RUN (fails: 1)` -- never ran, failed once. They are split because a
column with archives is a different thing from one with no history at all.

```bash
bash daily-report.sh
bash daily-report.sh -c -o reports/report-$(date '+%F').csv
```

One row per node, tab separated on stdout. The first column after the node name
is its Slurm state from `sinfo`, so a column of `NOT_RUN` can be read against
whether the node was drained the whole time rather than guessed at. Completed
jobs show extracted performance metrics (Gflops for HPL, busbw GB/s for
allreduce/alltoall) instead of a status string.

Nothing is written to disk unless `-o` names a file, and `-c` switches the
separator to commas. Run at a terminal the table is column-aligned; redirected
or piped it is the raw separated rows, so `cut -f2` and a spreadsheet both get
what they expect.

Under the table, on stderr, a summary counts the nodes in each Slurm state and
the cells holding each status, then gives `min`/`median`/`mean`/`max` per job
over the cells that hold a number. The statistics are per job rather than
pooled — Gflops, GB/s and MB/s share a table but not a scale. It stays on
stderr so neither `-o` nor a redirect ever gets prose mixed into the data.

At a terminal, the node table and every summary block are laid out on one grid:
no indentation, one set of column positions shared by all of them, and every
line a row — blocks are named by the first cell of their own header row rather
than by a title line above them. That is what makes the whole screen selectable
in one sweep and importable with text-to-columns in fixed-width mode. The import
picks a single set of break points and applies them to everything pasted, so
blocks that are each tidy on their own but disagree on where a column starts all
get sliced through the middle, and a free-form line like `254 nodes, 4 jobs` puts
words at offsets no boundary passes through. Widths are therefore measured across
every row of every block before anything prints.

`-c` does not change the summary: the separator governs the rows on stdout, not
the human block on stderr. A spreadsheet opening the `.csv` or `.tsv` written by
`-o` splits on the delimiter and needs none of this.

```bash
bash watch-rack.sh "rack01-node[1-32]"
```

Refreshes every 20 seconds, showing only nodes that are DOWN or drained.

## Health checks

```bash
bash health-check.sh                      # every node
bash health-check.sh ink50-dh01-h20       # one rack (bare prefix)
bash health-check.sh --full               # nothing elided
bash health-check.sh --summary            # roll-up: where every node stands
```

Reads the Slurm drain reasons and groups nodes by the *set* of checks they
failed, largest group first, so 60 nodes failing the same 38 checks read as one
incident with one fix rather than 38 check lists over 60 node lists. Also
separates operator drains from health drains — grouped by reason, so a
powered-off rack is one line — and flags any check with no entry in
`valid-config/default/`, because those can never pass: `node_health.sh` is
diffing against a file that is not there.

Long lists are elided with a count; `--full` prints everything. Node lists are
compressed and wrapped at range boundaries, so they paste straight into
`node-health-refresh.sh`.

Nothing is contacted or re-run: it reports what the last health run concluded.

### `--summary`

The default report answers "what do I fix". `--summary` answers "where does
every node stand" — each node lands in exactly one bucket, and the buckets add
up to the node count:

```
SUMMARY — 576 nodes

PASSING — 76 nodes (checks ran, nothing mismatched the baseline)
  ink50-dh01-h01-[11,14,17,29,32,35],ink50-dh01-h02-[11,14,17,29,32,35],...

FAILING HEALTH CHECKS — 60 nodes (drained by node_health.sh)
  ink50-dh01-h01-36,ink50-dh01-h02-[16,18,31],...

NOT CHECKED — 3 nodes (available, but no logs/<node> — checks have never run)
  ink50-dh01-h15-14,ink50-dh01-h19-11,ink50-dh01-h22-11

OTHER DRAINS — 437 nodes (operator or sequencer; health state not visible in Slurm)
  ink50-dh01-h01-[12-13,15-16,18,28,30-31,33-34,37],...
```

Two distinctions worth knowing:

- **PASSING vs NOT CHECKED.** Both are available with no drain reason. Only the
  first has a `logs/<node>` to show for it. A node that has never run
  `node_health.sh` is not a node that passed, and is not counted as one.
- **OTHER DRAINS is not a health verdict.** Those nodes are down or drained for
  a reason `node_health.sh` did not write, so it overwrote nothing and Slurm
  carries no health result for them either way. They may be perfectly healthy;
  Slurm cannot say.

`PASSING` also depends on the baseline being present — with a missing or
dangling `valid-config/default`, nodes reach it by having no reason recorded
rather than by matching anything, and the summary says so.

```bash
bash node-health-refresh.sh node001
bash node-health-refresh.sh "node00[1-18]"
```

Sets the `refresh` sentinel so the next monitoring cycle re-runs
`node_health.sh` on those nodes.

```bash
bash sync-check.sh node001
```

Diffs the node's health check output against the valid-config baseline for each
check listed in the Slurm drain reason — the fastest way to see why
`node_health.sh` took a node down.

```bash
bash set-valid-default.sh node001
```

Captures a validated node's `logs/` as the new baseline. See
[health-checks.md](health-checks.md).

## Node state

```bash
sinfo -n node001 -o '%T %E'          # state and reason
scontrol show node node001           # full detail
sinfo -R                             # every drained node with reasons
```

If the reason contains `auto-retry`, the sequencer put it there and will clear
it itself on the next retry pass — resuming by hand just starts the next sweep
sooner. Any other reason is an operator drain, and the sequencer will neither
clear it nor queue work behind it.

```bash
scontrol update nodename=node001 state=RESUME              # clears drain + reason
scontrol update nodename="node[001-018]" state=RESUME      # a whole rack
```

`RESUME` is what you want in almost every case — it clears the drain reason and
lets Slurm put the node back to `idle` or `alloc` on its own. Setting
`state=IDLE` directly is rejected from some states and skips that bookkeeping.
These commands need privilege — see
[Slurm permissions](sequencer.md#slurm-permissions).

## Pausing everything

Three switches in `SETTINGS` stop the framework doing anything, without
unregistering it from BCM. Edit them on the head node; every node reads the same
NFS-exported file, so a pause takes effect fleet-wide on the next monitoring
cycle.

```bash
PAUSE_JOBS=yes             # no benchmarks submitted; queued ones cancelled
PAUSE_HEALTH_CHECKS=yes    # no health checks run; Slurm untouched
PAUSE_CONTAINER_COPY=yes   # no new rsync into /tmp/containers
```

What that leaves running, in order of how long it takes to stop:

- **Pending benchmarks are cancelled on the first paused cycle.** They wrote
  nothing, and the sweep re-queues them when the pause lifts.
- **One benchmark per node may still be running**, and is left to finish — up to
  `MAX_JOB_HOURS`, so up to ~6.5 hours if it is a burn-in run. Its job id is in
  that node's `trigger.log`. To empty the cluster immediately instead:

  ```bash
  squeue -h -n bringup-<node> -o '%i %T'   # the sweep, on one node
  squeue -h -n burnin-<node>  -o '%i %T'   # its burn-in
  scancel -n burnin-<node>                 # stop just the burn-in, keep testing
  scancel -u cmods                         # every job the framework owns
  ```

  Each one killed leaves a part-written result file that the gate reads as
  `INCOMPLETE`, and the sweep retries it after the pause. That is the cost of a
  hard stop; it is not a failure of the node.
- **A detached `rsync` from an earlier cycle finishes.** It reads NFS into a
  local cache, holds no node and blocks no job.
- **Existing drains stay.** A pause neither drains nor resumes anything, so a
  node the sequencer drained before the pause stays drained, marker and all,
  and is picked up again when the pause lifts. Resume by hand if you need it
  back sooner.

Nothing is lost. Results stay on disk and the sweep resumes rather than
restarting, and a `refresh` set by `node-health-refresh.sh` is held through the
pause rather than consumed by a run that does nothing.

Confirming a pause is on, and that it is why the cluster is quiet:

```bash
bash trigger-log.sh                 # every node's last decision: PAUSE_JOBS=yes ...
bash trigger-debug.sh               # reports the switches in section 0, before the links
```

Both `status-check.sh` and `health-check.sh` print a banner while their half is
paused, because a report that cannot change looks exactly like a cluster that
has settled.

The switches are separate because they stop different things: pausing the
benchmarks during a maintenance window usually should *not* stop health checks
from telling you what state the nodes came back in.

## Disabling drains

Two settings decide whether a failure takes a node out of service. Both live in
`SETTINGS` (or `SETTINGS.default` when a site has not made a `SETTINGS`), and
both ship **off** — see [settings.md](settings.md).

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # node_health.sh: mismatch against baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # launch_job.sh: failed sweep, and MAX_JOB_HOURS
```

Nothing else changes with either off — checks and benchmarks still run, results
are still recorded, and failures still re-queue hourly. The node is simply never
taken out of service, so failures show up in `status-check.sh`, `sync-check.sh`
and `daily-report.sh` rather than in `sinfo`.

That is the state to be in during early bringup, when you want the full picture
across a rack before nodes start dropping out, and while debugging a benchmark
that is failing for reasons unrelated to the hardware.

Two consequences worth knowing before turning them on or leaving them off:

- With `DRAIN_AFTER_FAILED_HEALTH_CHECK=no`, `health-check.sh` reads the Slurm
  reason field and therefore reports every node as passing. It prints a banner
  saying so. Use `sync-check.sh <node>`, which diffs the logs directly, until
  drains are on.
- Turning either on does not clear drains that already exist, and does not
  drain a node that is already failing — the next monitoring cycle does that.

`DRAIN_AFTER_FAILED_HEALTH_CHECK` is the riskier of the two and should stay off
the longest: a health check drains on *any* diff against
`valid-config/default`, so a baseline taken from a node that is itself slightly
off drains the entire cluster on the first cycle. Bring it up only once
`bash health-check.sh --summary` reads clean across the fleet.

These replace the old `NODRAIN` file, which is gone. A `NODRAIN` left over from
an earlier deployment now does nothing; delete it.

## Debugging "nothing is running"

Two scripts, and the order matters. `trigger-log.sh` reads the record the
sequencer already wrote; `trigger-debug.sh` inspects the configuration that
should be producing it. Read the record first — it tells you which of the two
failures you have, and they are indistinguishable from the outside:

```bash
bash trigger-log.sh                       # whole cluster
bash trigger-log.sh ink50-dh01-h20        # one rack
bash trigger-log.sh ink50-dh01-h20-11     # one node — adds its raw trace
bash trigger-log.sh -w 2                  # only events from the last 2 hours
bash trigger-log.sh -s 30                 # a log is stale after 30m, not 15m
```

It prints five sections:

1. **Is the trigger firing?** — `results/<node>/trigger.log` write times. Every
   log stale means the sequencer is not being run anywhere, which is a BCM
   problem; nothing below it can be trusted, because the decisions on screen
   are whatever was true when it stopped.
2. **What each node last decided** — the last traced line per node, grouped by
   reason with node names and numbers normalized out, so a fleet collapses to a
   handful of distinct reasons instead of one line per node.
3. **Did anything get submitted?** — the question section 2 cannot answer alone.
   `every benchmark passing` and `next sweep in Ns` both look healthy and both
   mean no work went out.
4. **Failures and warnings** — `SUBMIT FAILED`, `WARNING`, `DRAIN`, missing
   `verdict.sh`, Slurm not on `PATH`, grouped the same way.
5. **Health-check side** — nodes with a `results/<node>` but no `logs/<node>`.
   `node_health.sh` never ran there, so the node never left DOWN and no
   benchmark could be scheduled onto it — a stuck bringup with a perfectly
   healthy sequencer, because the sequencer is not the thing that is stuck.

Read-only, and `-w`/`-s` only widen or narrow what it reports.

### Debugging the trigger chain

```bash
bash trigger-debug.sh                 # whole cluster
bash trigger-debug.sh ink50-dh01-h20  # one rack
```

Walks the chain from BCM down to `sbatch` and names the broken link: action
registered, trigger enabled *and* with its action actually bound, script
present, the last decision each node's sequencer made, and result-path
ownership. Read-only.

To ask a single node directly instead of waiting for a monitoring cycle:

```bash
pdsh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --explain'
```

`--explain` prints every gate the sequencer evaluates and the `sbatch` commands
it would issue, as a dry run — nothing is submitted, drained, or archived, so it
is safe while the trigger is live.

To make it act rather than report, without waiting for the hourly gate:

```bash
pdsh -w 'ink50-dh01-h20-[11,13-18]' '/home/cmods/bringup/actions/launch_job.sh --force -v'
pdsh -w ink50-dh01-h20-11           '/home/cmods/bringup/actions/launch_job.sh --all -v'
```

It sweeps the node it runs on and takes no node argument — an unrecognised one
is `exit 2` and nothing swept. `-v` is what gets the trace back through `pdsh`.
Run as `root` or as `cmods`.

`--force` sweeps now, queueing what the next open cycle would have queued;
`--all` additionally re-runs jobs that already passed. Neither adds anything to
`squeue` for a node that is paused, drained by an operator, down, running
somebody else's job, or already holding a batch of ours — those gates are
unchanged, and each says in `trigger.log` that `--force` did not override it.
See [sequencer.md](sequencer.md#running-it-by-hand).

Each node also keeps a running trace at `results/<node>/trigger.log`, one line
per monitoring cycle recording what it did or why it stopped.

## Debugging IB visibility

```bash
bash ib-visibility.sh ink50-dh01-h20-36
```

For the two NCCL `-nonvlink` jobs, which need the HCAs and fail four different
ways that all look the same from a bandwidth number. Takes under a minute
instead of an hour of walltime, and prints three sections in causal order:

1. **Host** — PCI devices, `/sys` and `/dev/infiniband`, what
   `nccl_hca_detect` picks after the bond/NVSwitch filter, and per-port state.
2. **Container** — the same image and mounts the job uses, `ibv_devinfo` (the
   call NCCL itself makes), ACTIVE-port count, and whether every device pinned
   in `NCCL_IB_HCA` on the host actually exists inside the container.
3. **NCCL init** — an 8-byte `allreduce_perf_mpi` with the job's environment
   and `NCCL_NET=IB`, filtered to the transport lines.

The first section that is wrong is the cause; the rest are consequences. The
case numbers it prints map to the reasons `status-check.sh` reports:

| Reported reason | Section that explains it |
| --- | --- |
| `no compute-plane HCA` (job self-reports `FAIL`) | host, case 1 |
| `no HCA visible inside the container` | container, case 2 |
| `no IB device visible to NCCL` | container, case 3 — ports not ACTIVE, or names pinned that the container cannot see |
| `collective carried over TCP` | NCCL init, case 4 |

## Resetting results

```bash
bash single-node-purge.sh node001 "node[002-004]"   # one or more nodes/nodelists
mv results results.$(date +%F)       # everything, kept
rm -rf results                       # everything, gone
```

Safe at any time — the tree is recreated and re-owned on the next monitoring
cycle. See [result-path ownership](sequencer.md#result-path-ownership) for why
ownership matters and how to fix a tree immediately.

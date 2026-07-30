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
bash status-check.sh -t 'allreduce*' -t dcgmi-r3 ink50-dh01-h20
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

`RETRY` and `NOT_RUN` used to be one status, which reported a column whose
attempt had just been archived as one that had never been attempted. They are
split because a column with archives is a different thing from one with no
history at all.

The line carries no attempt count. It is per node, so two nodes in the same
state print different lines and `dshbak` splits one block into a block per
count; the `.fail<N>.txt` archives on disk are the record of how many tries a
column took.

```bash
bash daily-report.sh
bash daily-report.sh -c -o reports/report-$(date '+%F').csv
```

One row per node, tab separated on stdout. The first column after the node name
is its Slurm state from `sinfo`, so a column of `NOT_RUN` can be read against
whether the node was drained the whole time rather than guessed at. A job that
produced a number shows it — Gflops for HPL, largest-message-size busbw GB/s for
allreduce/alltoall — whatever the verdict made of it. A status word in one of
those columns means there was no figure to print instead: the job never ran
(`NOT_RUN`), never finished (`INCOMPLETE`), or died before printing a result
(`FAIL`). Which cells passed is the `job (pass/fail)` block below, not the cell.

That matters for reading a slow node: a `-nonvlink` cell at 41 GB/s and one at
2.2 both fail the 43 GB/s floor, and they are a slow fabric and a socket
fallback. The floors are in `parsers/nvl72/verdict.sh` and are stated against
the same number these columns print, so the two can be compared directly.

Nothing is written to disk unless `-o` names a file, and `-c` switches the
separator to commas.

Under the table, on stderr, a summary counts the nodes in each Slurm state and
the cells holding each status, then gives `min`/`median`/`mean`/`max` per job
over the cells that hold a number, failing runs included — the min is the worst
node on the cluster, not the worst node that passed. The statistics are per job
rather than pooled — Gflops, GB/s and MB/s share a table but not a scale. It stays on
stderr so neither `-o` nor a redirect ever gets prose mixed into the data.

The last block is `job (pass/fail)`: one row per job, counting its cells by
status. It is the only summary a pass/fail job gets — `dcgmi-r3`, `stressapptest`
and `memtester` judge a node without producing a figure, so the metric block
has no row for them at all, and the pooled status counts above say how many
cells failed but not which job they belong to. It is counted from the status
rather than from the cell, so a job with a metric is broken out here too: its
cells hold a number that says nothing about whether the gate accepted it.

Both halves are laid out the same way, always, under one rule: **TSV at a
terminal** is column-aligned for reading, and **anything else** — a pipe, a
redirect, `-o`, or `-c` — is the raw separated rows.

### Getting it into a spreadsheet

Use `-c` and split on the delimiter. That gives comma separated rows for the
table *and* the summary, so a paste of the whole screen imports in one pass.
`daily-report.sh | cat` is the same thing with tabs, which most spreadsheets
split on paste without a dialog at all.

Do not import the aligned form with text-to-columns in fixed-width mode. It
looks like it should work and it does not: the import guesses where the columns
are from whatever was selected, so pasting one block gets different break points
than pasting the whole report, and either guess can land mid-word. No amount of
padding or shifting fixes that — a separator has nothing to guess. The aligned
form is for reading on screen.

When it is aligned, the node table and every summary block share one grid: no
indentation, one set of column positions measured across every row of every
block before anything prints, and every line a row — blocks are named by the
first cell of their own header row rather than by a title line above them, since
a free-form line like `254 nodes, 4 jobs` puts words at offsets no column
boundary passes through.

### How a report is produced

Both reports get their cells from `verdict-scan.sh`, which judges every
`(node, column)` pair and writes one row per cell. `status-check.sh` ignores the
metric field, `daily-report.sh` ignores the reason; neither walks the fleet
itself.

A verdict is derived on every read and never stored — see
[benchmarks.md#where-a-pass-is-decided](benchmarks.md#where-a-pass-is-decided) —
so a report is tens of thousands of independent judgements, and each one used to
fork a handful of `grep`s. Reading every result file on a large cluster takes
under a second; the cost was the process churn and the fact that one shell did
all of it in sequence. So the walk is chunked across `SCAN_JOBS` workers, and
the per-cell path forks as little as it can, any saving there being multiplied
by every cell on the cluster.

`verdict-scan.sh` is 644 and both sourced *and* run — sourced by the reports for
`scan_fleet()`, run by its own `xargs` as the worker, the same arrangement as
`node_health.sh` running each health check with `bash "$check_file"`. It is not
a command anyone invokes.

Two details in that file are easy to "fix" into a bug:

- **Rows are separated by ASCII US (`0x1f`), not a tab.** `read` splits on IFS
  but also collapses runs of it when IFS holds whitespace, so with a tab a row
  with an empty reason and a metric — every passing cell that produced a number
  — delivers the metric into the reason's variable and blanks the metric. The
  report then prints `DONE` in a column that has a figure for it, which reads
  like a broken gate and is one line of the reader.
- **Each row is written with a single `printf`.** Workers share one stdout, and
  on Linux a write under `PIPE_BUF` is atomic while a field-at-a-time `printf`
  is not.

The scan runs in child processes, so nothing it does can build state in the
calling shell. A caller wanting a per-node roll-up folds the rows itself.

### The verdict cache

Judged verdicts are kept in `results/.result_cache.<mode>`, one file per mode
because the two reports ask different questions of the same files.
[A repeat run goes from minutes to about a second](settings.md#the-verdict-cache)
on a large fleet.

This is the only thing in the tree that comes near storing a judgement, and what
makes it legitimate is what is in the key:

- **The gate.** `verdict.sh` and `verdict-scan.sh` are hashed in, so editing a
  floor invalidates every entry at once and the fleet is re-judged. Floors move
  here as the platform is learned; without this, those commits would change
  nothing and no output would say so.
- **Every result file under the node** — name, size and mtime, archives
  included. A new, changed or deleted result re-judges that node and no other.
  Size alone would miss a rewrite of equal length, so mtime is in there too.

Validity is per file, which is what makes the check one `find` for the fleet
rather than a read of every byte. Replay is per node, which keeps the rules
about which file feeds which cell — the archive fallback especially — in
`_scan_node()` rather than restated in awk where the two could drift.

Two things change an answer with no file changing, and both are kept out of the
cache rather than checked by it:

- A node with a job on it now. `RUNNING` comes from `squeue`, which is live
  state, and its files are being written as the report runs.
- **That same node's rows are never written down either.** Once the job ends,
  nothing on disk would invalidate a cached `RUNNING`, and the report would call
  a finished job live.

Anything added to a verdict that is not a pure function of the result file and
the gate does not belong in a cached row. `tests/scan-cache-test.sh` holds all
of this; a stale hit is silent, so that suite is what stands between a wrong key
and a clean-looking report of a broken cluster.

To clear it or bypass it, see
[settings.md#the-verdict-cache](settings.md#the-verdict-cache).

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

A missing or dangling `valid-config/default` is reported first, above the
groups, because it makes every check fail on every node that ran and none of
those failures are real — the report under it is an artifact of the baseline,
not a description of the cluster. Fix the baseline and read it again.

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

### Drains that clear themselves

Some of the drains in `sinfo -R` will go away without anyone touching them, and
knowing which is the difference between waiting a cycle and resuming a node by
hand. `slurm-recovery.sh` runs inside both actions and sorts every drain reason
into one of four classes:

| Class | The reason says | Who clears it |
|-------|-----------------|---------------|
| `marker` | it carries `DRAIN_MARKER` — this framework drained the node over a benchmark | `launch_job.sh`, once the benchmarks pass |
| `health` | it is a list of check names — `node_health.sh` drained the node | `node_health.sh`, on a clean run |
| `machine` | it matches `RECOVER_REASONS` (prolog, epilog, rogue process, failed launch, unexpected reboot, duplicate jobid, GRES count mismatch), or it is empty | the recovery, subject to the gates below |
| `operator` | anything else | nobody, ever |

**Operator drains are never cleared by anything in this tree**, and that is the
distinction the whole classification exists to protect. A node somebody took out
of service and a node Slurm drained over a lost epilog race look the same in
`sinfo`, and resuming the first one puts work back on a machine somebody is
standing in front of — invisibly, because the node returns to `idle` with the
reason gone and nothing left to say it was ever drained on purpose. A drain set
from a named admin account is left alone whatever its text says, and so are
`maint`, `reserved`, `planned` and `fail`. Free-text prose in the reason
(`waiting on RMA`, `bad NVLink, do not use`) is what keeps a drain out of the
`machine` class; the classification and its limits are in
[settings.md](settings.md#recovering-drains-slurm-set-itself), and
`tests/recover-test.sh` holds a case for each of them.

A `machine` drain is still only cleared once the condition behind it is gone —
`slurmd` answering, no compute processes left holding the GPUs, no job still
assigned. A node put back while still broken is re-drained within the minute,
and it is capped at `RECOVER_MAX_ATTEMPTS` inside `RECOVER_WINDOW_HOURS` for
that reason. Past the cap the drain is left exactly as Slurm set it rather than
re-drained under our own marker, which would only start the flapping again by
another route. Every decision, including the ones that changed nothing, is
written to `results/<node>/recover.log` and traced — so a node that is not
coming back says why, in the same place everything else does.

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

Fresh traces settle it on their own. Every gate the sequencer evaluates writes a
line to `results/<node>/trigger.log` before it stops, so a log written this cycle
means BCM fired, the action ran and the script reached a decision — the chain is
intact by definition, and whatever is holding the cluster is a gate that has
already named itself in section 2. There is nothing for `trigger-debug.sh` to
find in that case; it answers the other one, where the traces are stale, nothing
is writing them, and the question is which link between BCM and `sbatch` is
broken.

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

To try a job the site does not run — `jobs/$JOBS/` ships more than `BENCHMARKS`
names — `--test` runs it in place of the lists, without editing `SETTINGS`:

```bash
pdsh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh -t ethr -v'
```

It drains nothing and leaves `quick-view.txt` alone, so it cannot affect what
the fleet is judged on; the result has no column in the reports and is read with
`status-check.sh -t ethr`. See
[sequencer.md](sequencer.md#running-a-job-that-is-not-in-the-list).

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

`single-node-purge.sh` removes `results/<node>` outright, per node: the current
result file for every benchmark, every `.fail<N>.txt` and `.prev<N>.txt`
archive, `quick-view.txt`, `trigger.log` and `recover.log`. The node is then
`NOT_RUN` in every column with no history behind it, and the next sweep re-runs
the full benchmark set from scratch. Arguments are node names or nodelists
(`node00[1-18]`), expanded through `scontrol show hostnames`, and several may be
given at once; a name with no results directory is reported and skipped rather
than passed silently.

That is the right move after a hardware change — a swapped GPU, a reseated
cable, new firmware — where the results on disk describe a machine that no
longer exists and would otherwise keep a node in `RETRY` against failures it has
already grown out of. It also resets the recovery rate limit, since the log the
cap is counted from goes with the directory.

What it does not touch is the health side: `logs/<node>` and the
`valid-config/default` baseline survive, so a purge re-runs the benchmarks and
changes nothing about what `node_health.sh` concluded. To redo that half, use
`node-health-refresh.sh`.

Do not purge a node with a benchmark in flight. `sbatch --output` is already
holding that file open, so the running job writes into a directory that no
longer exists and the result never appears — which reads afterwards as a job
that ran and produced nothing. Check with `squeue -h -n bringup-<node>` first,
or purge after the sweep is idle.

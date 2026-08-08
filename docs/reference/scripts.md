# The operator scripts

Every entry point, what it takes and what it prints. Everything here runs from
the headnode and is safe to run while the triggers are live.

Nine of these implement `-h`/`--help` by printing their own header comment —
`status-check.sh`, `health-check.sh`, `overall_report.sh`, `daily-report.sh`,
`sync-check.sh`, `trigger-log.sh`, `kill-jobs.sh`, `check_squeue.sh` and
`build_llmb.sh`. **That header is the authoritative option list**, and it is
deliberately not restated here: two copies of a command surface drift, and only
one of them is testable.
`tests/help-text-test.sh` keeps the printed range in step with the text. Run
`<script> -h` for the flags; this page is what the output means.

## `status-check.sh` — live per-node benchmark status

```bash
bash status-check.sh                      # every node
bash status-check.sh ink50-dh01-h20        # one rack (bare prefix)
bash status-check.sh -t allreduce          # one benchmark, every run of it
bash status-check.sh -t 'allreduce*' -t dcgmi-r3 ink50-dh01-h20
bash status-check.sh -s                    # node lists per status, no reasons
```

Reads `results/` and prints per-node status for each benchmark column, grouped
by identical status via `dshbak`. A host that is not a compute node gets no row
and is named on stderr instead — see
[settings.md#hosts-that-are-not-compute-nodes](settings.md#hosts-that-are-not-compute-nodes).

| Status | Meaning |
| --- | --- |
| `DONE` | the gate accepted the result |
| `FAIL` | the job reported it could not run, or the gate rejected it |
| `INCOMPLETE` | no end marker and no job on the node — it died before finishing (crash, walltime, OOM) |
| `RETRY` | the last attempt was archived and a retry is queued; the reason shown is why that attempt was rejected — or, after `launch_job.sh --all` archived a passing result as `.prev<N>.txt`, that the re-run was asked for |
| `NOT_RUN` | no attempt has ever been made |
| `RUNNING` | a benchmark is executing on the node right now; nothing to judge until it writes its end marker |

`RETRY` and `NOT_RUN` used to be one status, which reported a column whose
attempt had just been archived as one that had never been attempted. A column
with archives is a different thing from one with no history at all.

The line carries no attempt count. It is per node, so two nodes in the same
state would print different lines and `dshbak` would split one block into a
block per count; the `.fail<N>.txt` archives on disk are the record of how many
tries a column took.

`-t` is repeatable and matched as written — no `*` is appended the way it is for
the node pattern, because benchmark names are prefixes of each other and
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

Columns for `BURNIN` jobs appear only while `RUN_BURNIN` is on, so an unused
burn-in list does not leave a permanent `NOT_RUN` column that reads like work
outstanding. Per node, `results/<node>/quick-view.txt` carries the state
directly: `BURN-IN OFF` when the switch is off, and `IN QUEUE` for anything
submitted and not yet judged.

## `daily-report.sh` — per-node table with metrics

```bash
bash daily-report.sh
bash daily-report.sh ink50-dh01-h20                 # one rack (bare prefix)
bash daily-report.sh 'ink50-dh0[12]*'               # glob, as written
bash daily-report.sh -c -o reports/report-$(date '+%F').csv
```

The node pattern is read exactly as `status-check.sh` reads its own: a bare
string gets a `*` appended, so a rack prefix covers the rack, and anything
holding `*`, `?` or `[` is used as typed and can match anywhere in the name.
With no pattern every node under `results/` is reported. A pattern matching no
node exits 1 and names the pattern rather than printing an empty table.

One row per node, tab separated on stdout. The first column after the node name
is its Slurm state from `sinfo`, so a column of `NOT_RUN` can be read against
whether the node was drained the whole time rather than guessed at. A job that
produced a number shows it — Gflops for HPL, largest-message-size busbw GB/s for
allreduce/alltoall — whatever the verdict made of it. A status word in one of
those columns means there was no figure to print instead: the job never ran
(`NOT_RUN`), never finished (`INCOMPLETE`), or died before printing a result
(`FAIL`). Which cells passed is the `job (pass/fail)` block below, not the cell.

That matters for reading a slow node: a `-nonvlink` cell at 41 GB/s and one at
2.2 both fail the `-nonvlink` floor, and they are a slow fabric and a socket
fallback. The floors are in `parsers/$PARSERS/verdict.sh` and are stated against
the same number these columns print, so the two compare directly.

Nothing is written to disk unless `-o` names a file, and `-c` switches the
separator to commas.

Under the table, on stderr, a summary counts the nodes in each Slurm state and
the cells holding each status, then gives `min`/`median`/`mean`/`max` per job
over the cells that hold a number, failing runs included — the min is the worst
node on the cluster, not the worst node that passed. The statistics are per job
rather than pooled: Gflops, GB/s and MB/s share a table but not a scale. It
stays on stderr so neither `-o` nor a redirect ever gets prose mixed into the
data.

The summary blocks are taken over the matched nodes and nothing else, so a
filtered report's `median` is that rack's median, not the fleet's — the `nodes`
count in the first summary block is what says how many nodes it was taken over.

The last block is `job (pass/fail)`: one row per job, counting its cells by
status. It is the only summary a pass/fail job gets — `dcgmi-r3`,
`stressapptest` and `memtester` judge a node without producing a figure, so the
metric block has no row for them at all, and the pooled status counts above say
how many cells failed but not which job they belong to. It is counted from the
status rather than from the cell, so a job with a metric is broken out here too:
its cells hold a number that says nothing about whether the gate accepted it.

Both halves are laid out the same way, always, under one rule: **TSV at a
terminal** is column-aligned for reading, and **anything else** — a pipe, a
redirect, `-o`, or `-c` — is the raw separated rows. Getting it into a
spreadsheet is [how-to/export-a-report.md](../how-to/export-a-report.md).

## `overall_report.sh` — everything without a pass

```bash
bash overall_report.sh                    # every node
bash overall_report.sh ink50-dh01-h20     # one rack (bare prefix)
bash overall_report.sh --full             # nothing elided
bash overall_report.sh -o reports/today.txt
```

The exception list. A node that passes appears nowhere in it, so a clean cluster
produces three lines — the counts, the settings file that was read, and the
sections saying they found nothing. Why it is inverted, and what that costs, is
[explanation/reading-the-whole-fleet.md](../explanation/reading-the-whole-fleet.md).

Four sections:

| Section | Rows are | Read from |
|---|---|---|
| `BENCHMARKS` | one column, then one group per `(status, reason)`, largest first | `results/<node>/`, judged by `parsers/$PARSERS/verdict.sh` |
| `HEALTH CHECKS` | one check, with the nodes whose log differs from the baseline | `logs/<node>/` against `valid-config/default/` |
| `NODES` | one block per node with an outstanding column, worst first | everything above, plus Slurm and the node's own trace |
| `WHAT TO RUN NEXT` | the commands that answer what the report raises | — |

A `FAIL` group carries `[measured …]` when the column has a metric, so how far
below a floor the nodes are is visible without opening `daily-report.sh`. The
figures are the same ones that report prints, in the same units.

The health section does **not** read Slurm drain reasons, so unlike
`health-check.sh` it is complete with the shipped
`DRAIN_AFTER_FAILED_HEALTH_CHECK=no`. Informational checks are excluded, because
`node_health.sh` never drains on them.

### A node block

Every line is `<label>  <value>`, and a label that is absent means that source
had nothing to say:

```
ink50-dh01-h20-35
    slurm    drained — 'Prolog error' set by slurm at 2026-08-07T03:09:55
    prolog   the pre-job check failed on [dmesg], 2026-08-07 03:10:12 (results/…/trigger.log)
    drains   3 cleared in the last 24h; last was a machine drain, drained, Prolog error
    queue    nothing of ours queued or running here
    health   2 failing: bios, kernel-params
    missing  allreduce (FAIL), alltoall (NOT_RUN)
    trace    2026-08-07 03:10:13 EXIT: waiting on our own queue (RUNNING for 12m, limit 7h)
```

`prolog` is the line the rest of this tree cannot give you: Slurm records only
that the prolog failed, and the check that actually failed is named nowhere a
head node can read it — except in the note `slurm-recovery.sh` leaves in the
node's own trace. When that note is absent the line says so and prints the `ssh`
that reads the node-local log directly. See
[explanation/reading-the-whole-fleet.md](../explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why).

`NODES` is capped by default and ordered so that what survives the cap is what
nothing else explains — a node with no result, no drain and no job in the queue
outranks one that simply has a benchmark running on it. `--full` lifts every cap
in the report.

Slurm is asked three times for the whole fleet, never once per node, so this is
safe to run while the triggers are live. It submits nothing, drains nothing and
resumes nothing; `-o` is the only thing it writes.

## `health-check.sh` — cluster-wide health summary

```bash
bash health-check.sh                      # every node
bash health-check.sh ink50-dh01-h20       # one rack (bare prefix)
bash health-check.sh --full               # nothing elided
bash health-check.sh --summary            # roll-up: where every node stands
bash health-check.sh --explain            # the cadence: when each node re-checks
bash health-check.sh --refresh node001    # queue a re-check ahead of the cadence
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
`health-check.sh --refresh`. Nothing is contacted or re-run: it reports what the
last health run concluded.

A missing or dangling `valid-config/default` is reported first, above the
groups, because it makes every check fail on every node that ran and none of
those failures are real — the report under it is an artifact of the baseline,
not a description of the cluster.

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

### `--explain` and `--refresh`

The report above reads Slurm, which knows what the last health run concluded and
nothing about when the next one is due. `--explain` answers that instead, from
the `logs/<node>/.last-check` stamps:

```
NODE                         LAST RUN             OUTCOME  NEXT DUE
ink50-dh01-h01-11            2026-08-08 04:12:31  clean    in 96m
ink50-dh01-h01-14            2026-08-08 07:31:02  failed   in 21m
ink50-dh01-h01-17            2026-08-07 22:04:55  clean    overdue by 6h
ink50-dh01-h01-29            (never)              -        next monitoring cycle
```

`overdue` is the one to read: the node is past its interval and has not
re-checked, so `NodeHealthTrigger` is not reaching it. `tail
results/<node>/health.log` names the gate. `(never)` on a node that has a
`logs/<node>` means the stamp predates the cadence, and one cycle fixes it.

`--refresh` takes node names and Slurm nodelists rather than a glob, repeatable,
and does nothing else — no report is printed, because the re-check it just
queued has not happened yet:

```bash
bash health-check.sh --refresh ink50-dh01-h01-14 'ink50-dh01-h02-[11-14]'
```

It needs write access to `logs/<node>/` and contacts no node. See
[explanation/health-cadence.md#asking-for-a-re-check](../explanation/health-cadence.md#asking-for-a-re-check).

## The rest

| Script | What it does |
|---|---|
| `sync-check.sh <node>` | Diffs the node's health output against the baseline for each check named in its Slurm drain reason — the fastest way to see why `node_health.sh` took a node down |
| `set-valid-default.sh <node>` | Captures a validated node's `logs/` as the new baseline — see [health-checks.md](health-checks.md) |
| `watch-rack.sh <nodelist>` | Refreshes every 20 seconds, showing only nodes that are DOWN or drained |
| `trigger-log.sh` | Reads `results/<node>/trigger.log` and `health.log` across the cluster — five sections, described in [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md). `--include-excluded` also reads the hosts the reports leave out |
| `actions/node_health.sh` | The health runner BCM fires. Also runnable over `pdsh` with `--explain`/`--force`/`--verbose` — see [how-to/run-a-job-by-hand.md#re-running-health-checks-by-hand](../how-to/run-a-job-by-hand.md#re-running-health-checks-by-hand) |
| `trigger-debug.sh` | Walks the BCM → `sbatch` chain and names the broken link. Read-only |
| `check_squeue.sh` | The queue in one aligned table, whole cluster; `-j <id>` adds node state and reservations |
| `kill-jobs.sh` | Cancels this framework's jobs; `-p` also sets `PAUSE_JOBS=yes`. See [how-to/pause-and-resume.md](../how-to/pause-and-resume.md) |
| `single-node-purge.sh <nodes>` | Removes `results/<node>` outright. See [how-to/reset-results.md](../how-to/reset-results.md) |
| `ib-visibility.sh <node>` | Compares the HCAs the host sees against the container's. See [how-to/diagnose-ib-visibility.md](../how-to/diagnose-ib-visibility.md) |
| `build_containers.sh` | Builds the `CONTAINERS` list. See [how-to/build-containers.md](../how-to/build-containers.md) |
| `build_llmb.sh` | Installs `llmb-run`, its image and tokenizer cache. See [how-to/enable-llm-pretrain.md](../how-to/enable-llm-pretrain.md) |

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
These commands need privilege — see [layout.md#slurm-permissions](layout.md#slurm-permissions).

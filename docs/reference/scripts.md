# The operator scripts

Every entry point, what it takes and what it prints. Everything here runs from
the headnode and is safe to run while the timers are live.

Every script below is `<group>_<name>.sh` — `report_benchmarks.sh`,
`check_trigger-log.sh` — specifically so the name says the command: `abup
<group> <name>` runs it, forwarding anything after `<name>` unchanged. `abup
-h` lists what's actually in the tree rather than a copy of this page that
could drift from it. See
[how-to/install-abup.md](../how-to/install-abup.md). Every example on this
page is written as `bash <script>.sh ...`; substitute `abup <group> <name>
...` for any of them.

Eleven of these implement `-h`/`--help` by printing their own header comment —
`report_job-status.sh`, `report_health.sh`, `report_overall.sh`, `report_benchmarks.sh`,
`check_trigger-log.sh`, `admin_kill-jobs.sh`, `check_squeue.sh`,
`build_llmb.sh`, `check_dmesg.sh`, `check_next-run.sh` and `admin_pause-agents.sh`.
**That header is the authoritative option list**, and it is
deliberately not restated here: two copies of a command surface drift, and only
one of them is testable.
`tests/help-text-test.sh` keeps the printed range in step with the text. Run
`<script> -h` for the flags; this page is what the output means.

## `report_job-status.sh` — live per-node benchmark status

```bash
bash report_job-status.sh                      # every node
bash report_job-status.sh ink50-dh01-h20        # one rack (bare prefix)
bash report_job-status.sh -t allreduce          # one benchmark, every run of it
bash report_job-status.sh -t 'allreduce*' -t dcgmi-r3 ink50-dh01-h20
bash report_job-status.sh -s                    # node lists per status, no reasons
bash report_job-status.sh --sort-by-hostname    # by node instead of by test
```

Reads `results/` and prints per-node status for each benchmark column, grouped
by identical status — see [grouping identical rows](#grouping-identical-rows).
A host that is not a compute node gets no row and is named on stderr instead —
see [settings.md#hosts-that-are-not-compute-nodes](settings.md#hosts-that-are-not-compute-nodes).

| Status | Meaning |
| --- | --- |
| `DONE` | the gate accepted the result |
| `FAIL` | the job reported it could not run, or the gate rejected it |
| `INCOMPLETE` | no end marker and no job on the node — it died before finishing (crash, walltime, OOM) |
| `RERUNNING` | a **passing** result was archived as `.prev<N>.txt` by `launch_job.sh --all` and the re-run is queued; also a rejected attempt that the current gate now accepts |
| `NOT_RUN` | no attempt has ever been made |
| `RUNNING` | a benchmark is executing on the node right now; nothing to judge until it writes its end marker |

A column whose last attempt was rejected reads `FAIL` for the whole time the
retry is queued, off the `.fail<N>.txt` archive — the reason is that attempt's,
with `a re-run is queued` appended. Why the gap is not a status of its own is
[verdicts-and-the-cache.md#a-column-between-two-attempts](../explanation/verdicts-and-the-cache.md#a-column-between-two-attempts).

The line carries no attempt count. It is per node, so two nodes in the same
state would print different lines and the grouping would split one block into a
block per count; the `.fail<N>.txt` archives on disk are the record of how many
tries a column took.

`-t` is repeatable and matched as written — no `*` is appended the way it is for
the node pattern, because benchmark names are prefixes of each other and
`-t allreduce` would otherwise drag in `allreduce-nonvlink`. It matches either
the job name (`-t allreduce` → every run) or a full column (`-t allreduce-run2`
→ that run). A pattern matching no active benchmark exits 1 and lists what is
active, rather than printing an empty report that reads like a clean cluster.

`-s` replaces the per-column report with one compressed node list per status
(FAIL / INCOMPLETE / NOT_RUN / RERUNNING / DONE), reasons dropped, for pasting into
`scancel`, `clush -w` or `scontrol`:

```
SUMMARY — judged on: allreduce

FAIL — 2 nodes (ran and was rejected by the current gate)
ink50-dh01-h20-[03,17]
```

Every node appears in exactly one list, under the worst status it holds across
the selected tests (FAIL > INCOMPLETE > NOT_RUN > RERUNNING > DONE), so the lists
are disjoint and a node cannot be acted on twice. DONE there means *every*
selected test passes, not that some did. The header names the tests the roll-up
covers, because a `-t`-scoped list that does not say so is one paste away from
draining nodes over a test they were never judged on.

Columns for `BURNIN` jobs appear only while `RUN_BURNIN` is on, so an unused
burn-in list does not leave a permanent `NOT_RUN` column that reads like work
outstanding. Per node, `results/<node>/quick-view.txt` carries the state
directly: `BURN-IN OFF` when the switch is off, and `IN QUEUE` for anything
submitted and not yet judged.

### The order of the report

The report is ordered by test: the benchmark columns are walked in the order
`BENCHMARKS` (then `BURNIN`) configures them, and each test's blocks are printed
together under a banner, so one test's whole fleet reads as one section:

```
************************************************************
allreduce-nonvlink
************************************************************
ink50-dh01-h20-[03,17]: allreduce-nonvlink: FAIL -- peak busbw below floor 93 GB/s
```

That is the order the jobs run in and the order `-t` names them in, so narrowing
with `-t` removes sections from the report rather than rearranging it. The
column stays on every line as well as in the banner: the grouping tool prints
its own rules between blocks, and a line that carries its own column is still
one grep away from being read on its own.

`--sort-by-hostname` orders by node instead: every row sorted by node name, so
one node's columns sit together and the tests are interleaved. It is the shape
to reach for when the question is about a node rather than about a benchmark.

The grouping tool below sorts its own output, so the test order cannot come from
sorting the rows — the report is one invocation of it per column, over a single
scan split by column. That is also why the two orders are a flag and not a
`sort` pipeline the reader could write themselves.

### Grouping identical rows

Two hundred nodes reporting the same thing is one fact, not two hundred lines,
so the report is piped through a tool that collapses `<node>: <line>` input into
one block per distinct line under a compressed nodeset. Either of two will do:

| Tool | Ships with | Called as |
|---|---|---|
| `clubak` | ClusterShell, alongside `clush` | `clubak -b` |
| `dshbak` | `pdsh` | `dshbak -c` |

`bak_resolve` in `fanout.sh` prefers `clubak`, honours `FANOUT_TOOL` when it is
pinned, and falls back to `dshbak`. **A site installing ClusterShell for `clush`
gets `clubak` in the same package and needs nothing else** — `pdsh` is not
required just for the grouped report.

With neither installed the report prints one line per node and says so on
stderr. That is the whole reason the check exists: a missing grouping tool
empties stdout while the pipeline still exits 0, which is indistinguishable from
"no nodes match".

The lines are built to group well. The reason is on the line rather than in a
column, and the line carries no per-node attempt count, so nodes failing the
same way collapse into one block instead of one block per count. `verdict.sh`
keeps `REASON` identical across nodes for the same fault and puts the varying
part — the offending GPU, the measured bandwidth — in the detail. See
[explanation/judging-benchmarks.md](../explanation/judging-benchmarks.md).

## `report_benchmarks.sh` — per-node table with metrics

```bash
bash report_benchmarks.sh
bash report_benchmarks.sh ink50-dh01-h20                 # one rack (bare prefix)
bash report_benchmarks.sh 'ink50-dh0[12]*'               # glob, as written
bash report_benchmarks.sh -c -o ~/report-$(date '+%F').csv
```

The node pattern is read exactly as `report_job-status.sh` reads its own: a bare
string gets a `*` appended, so a rack prefix covers the rack, and anything
holding `*`, `?` or `[` is used as typed and can match anywhere in the name.
With no pattern every node under `results/` is reported. A pattern matching no
node exits 1 and names the pattern rather than printing an empty table.

One row per node, tab separated on stdout. The first column after the node name
is its Slurm state from `sinfo`, so a column of `NOT_RUN` can be read against
whether the node was drained the whole time rather than guessed at. A job that
produced a number shows it — Gflops for HPL, largest-message-size busbw GB/s for
allreduce/alltoall, median step time in ms for the two LLM jobs — whatever the
verdict made of it. A status word in one of
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
the cells holding each status, then gives `min`/`median`/`mean`/`max`/`cov` per
job over the cells that hold a number, failing runs included — the min is the
worst node on the cluster, not the worst node that passed. `cov` is the
coefficient of variation across those cells, which is how tightly the fleet
agrees with itself; it is unit-free, so it is the one column comparable between
jobs. See
[explanation/reading-the-whole-fleet.md#the-spread-column](../explanation/reading-the-whole-fleet.md#the-spread-column).
The statistics are per job
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

Both halves follow one rule: **TSV at a terminal** is column-aligned for
reading, and **anything else** — a pipe, a redirect, `-o`, or `-c` — is the raw
separated rows. It is asked of each stream on its own, so `report_benchmarks.sh >
/dev/null` still prints the summary aligned. Getting it into a
spreadsheet is [how-to/export-a-report.md](../how-to/export-a-report.md).

## `report_overall.sh` — the fleet in one line per node

```bash
bash report_overall.sh                    # every node
bash report_overall.sh ink50-dh01-h20     # one rack (bare prefix)
bash report_overall.sh --details          # the long report, with every reason
bash report_overall.sh --full             # that report, nothing elided
bash report_overall.sh --csv              # the exceptions, as columns
bash report_overall.sh -o ~/today.txt
```

One line per node — whether it is cycling, what Slurm calls it, then `PASS` or
the names of what is not passing on it — grouped through `clubak`/`dshbak` so
that every node saying the same thing is one entry under one compressed node
list:

```
---------------
ink50-dh01-h20-[03-07,11] (6)
---------------
 UP **** MIXED **** tests - allreduce hpl **** healthchecks - bios kernel-params
---------------
ink50-dh01-h20-19 (1)
---------------
 DOWN **** DRAINED **** tests - PASS **** healthchecks - bios
---------------
ink50-dh01-h20-[01-02,08-10,12-18] (12)
---------------
 UP **** IDLE **** tests - PASS **** healthchecks - PASS
```

The size of a group is the size of the incident, which is the same argument
`report_health.sh` makes for grouping by the *set* of failed checks. One line
rather than two, so the grouping is over the whole verdict — a node failing
`hpl` with clean checks and one failing `hpl` with a bad BIOS are two different
faults and must not fold together.

**Names, nothing else.** Not why a benchmark has no pass, and not how it failed:
whether a column was rejected, never attempted or is mid-retry is a question for
`--details`, and putting it on the line would split one group of sixty into six
of ten. All four fields are always spelled out, with `PASS` under a half that
has nothing outstanding, so every line has one shape and no field is ever empty;
the report prints a legend above the groups so the line itself carries no words
it does not need.

| Field | Is |
|---|---|
| `UP` / `DOWN` | whether `results/<node>/.heartbeat` has been written in `HEARTBEAT_STALE_MINUTES`. Not a probe — see [explanation/the-agent-and-the-watchdog.md](../explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means) |
| `<state>` | `sinfo`'s state for the node, uppercased. `UNKNOWN` when `sinfo` has no row for it, `NO-SLURM` when `sinfo` itself did not answer — neither of which is a state |
| `tests - ` | every benchmark column with no passing result, or `PASS` |
| `healthchecks - ` | every check whose `logs/<node>/<check>` differs from `valid-config/default`, or `PASS` |

When `RUN_BURNIN` is on, a `BURN-IN` section follows the groups, in both the one-line
and the `--details` report: `<node>: <N>H/<BURNIN_HOURS>H`, grouped by the same tool so
nodes at the same hours are one entry. Without `clubak`/`dshbak` it is one line per node.

The first two fields are the node rather than the work on it, and they come
first because everything after them is read from files: a `DOWN` node's two
halves are the last thing written rather than what is true now, and the count of
those nodes is in the `NOTE:` block above the groups.

**A column that never ran reads the same as one that was rejected**, because
neither is passing. So do the checks on a node with no `logs/<node>` at all, and
the checks on *every* node when there is no `valid-config/default`: nothing was
compared, so nothing passed, and every gated check is named. A half with nothing
under it prints `PASS`, and none of those three is a pass.

### `--csv` — the same fields, as columns

The four fields above with the prose taken out, one row per node, for pasting
into a spreadsheet or a ticket:

```
node,heartbeat,slurm,tests,healthchecks
ink50-dh01-h20-03,UP,MIXED,allreduce hpl,bios kernel-params
ink50-dh01-h20-19,DOWN,DRAINED,PASS,bios
```

Commas separate the five columns and nothing quotes, because no field can hold
one: the state is a single uppercased token and the two lists are
space-separated names. A row is a node, in the order the report walks them —
there is no `clubak` grouping, since a compressed node list is not a
spreadsheet cell.

**Only the nodes that need acting on.** A node that is `UP`, `IDLE` or
`ALLOCATED`, and passing both halves, is left out — it is the whole reason the
one-line report is grouped, and a CSV cannot fold sixty identical rows into
one. Every other combination stays, including a `DOWN` node passing both
halves: the heartbeat is the field saying whether the rest is current. When
nothing is outstanding, the header prints alone and the count of nodes goes to
stderr, so stdout stays paste-able and an empty report is still an answer.

It does not combine with `--details`, which is a different report rather than a
different format for this one.

### `--details` — everything without a pass

The exception list, and what this script printed by default before the one-line
report. A node that passes appears nowhere in it, so a clean cluster produces
three lines — the counts, the settings file that was read, and the sections
saying they found nothing. Why it is inverted, and what that costs, is
[explanation/reading-the-whole-fleet.md](../explanation/reading-the-whole-fleet.md).

Four sections:

| Section | Rows are | Read from |
|---|---|---|
| `BENCHMARKS` | one column, then one group per `(status, reason)`, largest first | `results/<node>/`, judged by `parsers/$PARSERS/verdict.sh` |
| `HEALTH CHECKS` | one check, with the nodes whose log differs from the baseline | `logs/<node>/` against `valid-config/default/` |
| `NODES` | one block per node with an outstanding column, worst first | everything above, plus Slurm and the node's own trace |
| `WHAT TO RUN NEXT` | the commands that answer what the report raises | — |

A `FAIL` group carries `[measured …]` when the column has a metric, so how far
below a floor the nodes are is visible without opening `report_benchmarks.sh`. The
figures are the same ones that report prints, in the same units.

The health section does **not** read Slurm drain reasons, so it is complete with
the shipped `DRAIN_AFTER_FAILED_HEALTH_CHECK=no`. It is rendered by
`health-scan.sh`, the same library `report_health.sh --summary` prints through,
so the two agree by construction. Informational checks are excluded, because
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
node's own trace, or its retained `recover.log` record after the trace rotates.
When neither has it, the line says so and prints the fan-out line that reads
the node-local log directly. See
[explanation/reading-the-whole-fleet.md](../explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why).

`NODES` is capped by default and ordered so that what survives the cap is what
nothing else explains — a node with no result, no drain and no job in the queue
outranks one that simply has a benchmark running on it. `--full` lifts every cap
in the report.

Slurm is asked three times for the whole fleet, never once per node, so this is
safe to run while the timers are live: `sinfo` for state and drain reason,
`squeue` for the queue, and `scontrol` to compress node lists and expand another
user's job. The one-line default needs none of state, drain, queue text or the
per-node traces, so it asks only `squeue` and skips the `trigger.log` and
`recover.log` sweeps entirely — it is the cheaper report as well as the shorter
one. Both submit nothing, drain nothing and resume nothing; `-o` is the only
thing either writes.

## `report_health.sh` — cluster-wide health summary

```bash
bash report_health.sh                      # every node
bash report_health.sh ink50-dh01-h20       # one rack (bare prefix)
bash report_health.sh ink50-dh01-h20-[03,17]     # a Slurm nodelist
bash report_health.sh node001 node017 node022    # names, in one report
bash report_health.sh --drained            # every drain, grouped by reason
bash report_health.sh --summary            # the per-check roll-up, complete
bash report_health.sh --by-state          # that roll-up, split by Slurm state
bash report_health.sh --individual ib-firmware   # aggregate that check across all nodes
bash report_health.sh --diff node001       # why one node failed, check by check
bash report_health.sh --explain            # the cadence: when each node re-checks
bash report_health.sh --refresh node001    # queue a re-check ahead of the cadence
```

Groups nodes by the *set* of checks they failed, largest group first, so 60
nodes failing the same 46 checks read as one incident with one fix rather than
46 check lists over 60 node lists. Also separates the drains it cannot account
for from the health failures — grouped by reason, so a powered-off rack is one
line — and flags any check with no entry in `valid-config/default/`, because
those are never compared and so can never pass.

The verdict comes from `logs/<node>/<check>` against `valid-config/default`, the
same byte-for-byte comparison `node_health.sh` drains on and the same one
`report_overall.sh` prints — one library, `health-scan.sh`, so the two reports
cannot disagree. Slurm is asked for node state and for drain reasons, nothing
else. A failing node therefore appears here whether or not
`DRAIN_AFTER_FAILED_HEALTH_CHECK` is on; see
[../how-to/manage-drains.md#running-with-drains-off](../how-to/manage-drains.md#running-with-drains-off).

Long lists are elided with a count; `--summary` is the complete list. Node lists
are compressed and wrapped at range boundaries, so they paste straight into
`report_health.sh --refresh`. Nothing is contacted or re-run: it reports the logs
the last health run left behind.

A missing or dangling `valid-config/default` is reported first, above the
groups, because nothing can be compared without it — every node then reads as
passing, and an empty report looks exactly like a healthy cluster.

### The node filter

Optional, repeatable, and the same in every mode — the argument after
`--individual <check>` and the arguments to `--diff` and `--explain` are read
exactly like the ones to the default report. Several arguments are one report
over all of them. With none, every node Slurm knows about is reported.

| Spelling | Example | Matches |
|---|---|---|
| Slurm nodelist | `dh01-h02-[11-14]`, `node001,node017` | exactly those nodes, expanded through `scontrol show hostnames` |
| bare string | `dh01-rack01` | every node whose name starts with it — a rack prefix covers the rack |
| glob | `dh01-rack0[12]*`, `*node05` | as written, anywhere in the name |

A glob is anything carrying a `*` or a `?`. **Brackets alone are a nodelist**,
so `node0[12]` is the node `node012` and not the two-node glob — add a `*` for
the glob. Why that way round:
[explanation/reading-the-whole-fleet.md#three-spellings-of-a-node-list](../explanation/reading-the-whole-fleet.md#three-spellings-of-a-node-list).

An argument nothing matched is named in a `NOTE:` above the report rather than
dropped, and the rest of the filter is still reported. A node that has never
been armed and a typo are the same string here, and neither is a clean node.

`--refresh` is the exception: it takes names and nodelists only, and refuses a
glob — see `--explain` and `--refresh` below.

### `--drained`

What is out of the queue, rather than what is broken. Every drained or down node
grouped by the reason it carries, largest group first, with the node list under
each:

```
DRAINED — 78 of 576 nodes

  drained        nvlinks nvlink-ber                            60 nodes
      ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34]
  down           Not responding                                15 nodes
      ink50-dh01-h07-[11-25]
  drained        (logs now match) bios                          2 nodes
      ink50-dh01-h09-[14,17]
  drained        admin: waiting on RMA                          1 node
      ink50-dh01-h11-22
```

`sinfo -R` answers the same question one node at a time, and a rack powered off
by CMDaemon reads there as eighteen incidents. Here it is one line, and stays
one line however many racks get added — which is what makes an unfamiliar reason
in a group of one worth reading.

The state is kept in the grouping key as well as the reason: `down` and
`drained` over the same text are two different situations, and a node that is
down with nothing recorded is its own group rather than being folded into the
drains.

`(logs now match)` marks a health drain the logs no longer support — see [a
drain the logs no longer
support](../how-to/manage-drains.md#a-drain-the-logs-no-longer-support). Nothing
elides, and nothing else is printed: this mode does not read the health verdict
except to mark those lines.

It does not combine with `--summary`. They are two reports, not two filters —
one groups failures by check, the other groups drains by reason — so asking for
both is an error rather than a silently ignored flag.

### `--summary`

The per-check roll-up instead of the grouped report: one line per failing check
with every node under it, largest first, then the checks with no baseline entry
and the nodes that have never been checked. Nothing elides.

```
── HEALTH CHECKS ───────────────────────────────────────────
3 checks failing on 60 nodes (logs/<node> against valid-config/default)

    nvlinks                   60 nodes
      ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34]
    ib-firmware                8 nodes
      ink50-dh01-h01-[11-18]
```

This is the same block `report_overall.sh` prints under HEALTH, rendered by the
same function from the same numbers, so the two can be compared line for line.
The default report groups by node — "what do I fix" — and this one groups by
check — "how far does each fix reach".

A node with no `logs/<node>` at all is listed separately as never checked. It is
not a passing node, and is not counted as one.

### `--by-state`

`--summary` split into one block per Slurm state, each with its own per-check
tally, largest state first. It implies `--summary`, so `--by-state` on its own is
the whole flag:

```
── HEALTH CHECKS ───────────────────────────────────────────
3 checks failing on 193 nodes, by Slurm state (logs/<node> against valid-config/default)

Slurm state: idle — 97 nodes
    nvlinks                   97 nodes
      ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34]
    dmesg-xid                 96 nodes
      ink50-dh01-h01-[11-35],ink50-dh01-h02-[11-34]

Slurm state: drained — 96 nodes
    nvlinks                   96 nodes
      ink50-dh01-h07-[11-36]
```

The flat roll-up counts a node that is already drained the same as one still
taking work, so `nvlinks — 193 nodes` cannot tell you how much of that a drain
would actually take out of the queue. This split can, and it is also where a
check failing only on nodes that are already down shows itself as the
consequence of the outage rather than a fault of its own.

The state comes from `sinfo`, and a failing node Slurm does not know about is
grouped under `unknown` rather than dropped.

### `--individual`

```bash
bash report_health.sh --individual ib-firmware
bash report_health.sh --individual ib-firmware ink50-dh01-h01   # one rack
```

Group nodes whose `logs/<node>/<check>` file is byte-for-byte identical, largest
group first, with a compressed node list and the file content under each:

```
ib-firmware — 2003 nodes

1999 nodes
  nscale-h01-[11-36],nscale-h02-[11-34],...
########INFO: Check IB FW (Expected: All nodes have the same FW version)
             /sys/class/infiniband/mlx5_0/fw_ver     40.48.1126
             ...

4 nodes
  nscale-h03-[11-14]
########INFO: Check IB FW (Expected: All nodes have the same FW version)
             /sys/class/infiniband/mlx5_0/fw_ver     40.47.2628
             ...
```

The default report tells you *which nodes* failed a check; this tells you *what
values* the fleet has and which nodes share each one. It reads no Slurm state.

### `--diff`

```bash
bash report_health.sh --diff ink50-dh01-h01-11
bash report_health.sh --diff --all ink50-dh01-h01-11
bash report_health.sh --diff 'ink50-dh01-h01-[11-14]'   # one block per node
```

Why one node failed: each check it fails, diffed against `valid-config/default`.

```
ink50-dh01-h01-11  (drained: nvlinks)
  <  this node
  >  baseline (ink50-dh01-h05-22)

--- nvlinks
2c2
< links 0
---
> links 228

2 of 41 checks differ
```

**`<` is the node and `>` is the baseline.** Read backwards, one bad baseline
reads as a fleet of bad nodes.

Which checks are diffed comes from `logs/<node>` against the baseline — the same
verdict every other view here uses — **not** from the Slurm drain reason. The
drain on the header line is context: it is what Slurm was told, and it goes stale
in both directions. A fault appearing after the drain was set is not in the
reason, and with `DRAIN_AFTER_FAILED_HEALTH_CHECK=no` there is no reason at all,
yet the node still diffs.

`--all` diffs every gated check rather than only the failing ones and lists the
matching names at the end — the view to use when the baseline itself is
suspect. Informational checks are excluded from both forms, because they are
recorded per rack and never judged against a cluster-wide baseline; read those
directly with `less logs/<node>/<check>`. See
[health-checks.md#informational-checks](health-checks.md#informational-checks).

The argument is a node pattern like every other one here, so a rack prefix
diffs the rack. One node per failure group is normally enough.

### `--explain` and `--refresh`

The report above reads a snapshot of the logs, which says what the last health
run concluded and nothing about when the next one is due. `--explain` answers
that instead, from the `logs/<node>/.last-check` stamps:

```
NODE                         LAST RUN             OUTCOME  NEXT DUE
ink50-dh01-h01-11            2026-08-08 04:12:31  clean    in 96m
ink50-dh01-h01-14            2026-08-08 07:31:02  failed   in 21m
ink50-dh01-h01-17            2026-08-07 22:04:55  clean    overdue by 6h
ink50-dh01-h01-29            (never)              -        next agent cycle
ink50-dh01-h01-33            2026-08-07 11:26:20  failed   not cycling — no check re-runs here
```

`overdue` is the one to read: the node is past its interval and has not
re-checked, so no agent cycle is reaching it. `tail
$HEALTH_LOG_DIR/<node>/health.log` names the gate. `(never)` on a node that has a
`$HEALTH_LOG_DIR/<node>` means the stamp predates the cadence, and one cycle fixes it.

| `NEXT DUE` | What it means |
|---|---|
| `in 96m` | cycling, and the interval has that long to run |
| `overdue by 6h` | cycling, past its interval — read the trace for the gate |
| `refresh queued` | a sentinel is waiting; the next cycle consumes it |
| `never (cadence off)` | both intervals are `0`, so only `--refresh` re-runs them |
| `next agent cycle` | no stamp yet — the checks have not run since the cadence was deployed |
| `not cycling` | no heartbeat in `HEARTBEAT_STALE_MINUTES`; nothing there reaches any gate, so no due time would be acted on |

`not cycling` displaces every other value, including `refresh queued`, and the
footer counts them. It is an agent fault rather than a health one — see
[explanation/health-cadence.md#a-due-time-assumes-a-live-node](../explanation/health-cadence.md#a-due-time-assumes-a-live-node),
and `./check_trigger-log.sh` section 0 to fix it.

`--refresh` takes node names and Slurm nodelists rather than a glob, repeatable,
and does nothing else — no report is printed, because the re-check it just
queued has not happened yet:

```bash
bash report_health.sh --refresh ink50-dh01-h01-14 'ink50-dh01-h02-[11-14]'
```

Because it takes names, a tool that produces them composes with it directly —
which is usually what someone reaching for a glob actually wanted:

```bash
bash report_health.sh --refresh $(nodeset -e @IDLE)          # ClusterShell
bash report_health.sh --refresh "$(sinfo -h -t idle -o %N)"  # Slurm, anywhere
```

`nodeset` ships with ClusterShell, so it is there on a `clush` site and absent
on a `pdsh`-only one; `sinfo` is there wherever Slurm is. The quoting differs
and both are deliberate: `nodeset -e` prints space-separated names and is left
unquoted so the shell splits them into arguments, while `sinfo -o %N` prints one
compressed nodelist that must stay a single argument for `scontrol show
hostnames` to expand.

A glob is refused rather than passed through. `--refresh 'ink50*'` is the one
spelling every *other* mode accepts, and unquoted it reaches the script as a
literal name once the shell finds no file to expand it against; the refusal
prints both spellings above, and the nodeset of the `logs/` directories it would
have matched, ready to paste back. Quote a nodeset, or the shell expands the
brackets before the script sees them.

A name with no `logs/<node>` queues nothing and says so without predicting: a
node that has never run the checks and a typo are the same string here, and only
the first one ever cycles.

It needs write access to `logs/<node>/` and contacts no node — so it queues
successfully on a node that has stopped cycling, and says so on the same line
rather than reporting a re-check that will not happen. See
[explanation/health-cadence.md#asking-for-a-re-check](../explanation/health-cadence.md#asking-for-a-re-check).

## The rest

| Script | What it does |
|---|---|
| `admin_set-baseline.sh <node>` | Captures a validated node's `logs/` as the new baseline — see [health-checks.md](health-checks.md) |
| `check_rack.sh <nodelist>` | Refreshes every 20 seconds, showing only nodes that are DOWN or drained |
| `check_trigger-log.sh` | Reads the heartbeats, `results/<node>/trigger.log` and `health.log` across the cluster — six sections, described in [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md). `--include-excluded` also reads the hosts the reports leave out |
| `agent/cycle.sh` | What `bringup-agent.timer` runs on every host. Asks `agent_role` and hands over to `supervisor.sh` or `node-agent.sh` — one unit for both, because `$HOME` is shared. See [explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles](../explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles) |
| `agent/node-agent.sh` | One cycle on the node it runs on: heartbeat, busy gate, then the three steps. Fired by `bringup-agent.timer`; `--explain`/`--verbose` for a hand-run over `clush` or `pdsh` |
| `agent/supervisor.sh` | The head node's watchdog. Fired by `bringup-supervisor.timer`; `--explain` names what it would arm and drain, and does neither |
| `agent/install-agent.sh` | Arms this host — lingering, the units, the timer. Idempotent; `--node`/`--head` override the role it works out for itself. See [how-to/arm-a-node.md](../how-to/arm-a-node.md) |
| `agent/uninstall-agent.sh` | Stops and removes the timer and its unit. Leaves lingering and everything under `results/` alone |
| `actions/file_copy.sh` | Warms this node's container cache. `--explain` itemizes the exact rsync changes without copying or writing state — see [explanation/containers.md#previewing-a-copy](../explanation/containers.md#previewing-a-copy) |
| `actions/node_health.sh` | The health runner, second of the agent's three steps. Also runnable over `clush` or `pdsh` with `--explain`/`--force`/`--verbose` — see [how-to/run-a-job-by-hand.md#re-running-health-checks-by-hand](../how-to/run-a-job-by-hand.md#re-running-health-checks-by-hand) |
| `check_next-run.sh` | The other half of `check_trigger-log.sh`: when each node next submits a benchmark (`--tests`) or runs its health checks (`--healthchecks`), bucketed into `soon` and one bucket per hour and grouped with `clubak`. Read-only. See [how-to/see-what-fires-next.md](../how-to/see-what-fires-next.md) |
| `check_trigger-debug.sh` | Walks the watchdog → `sbatch` chain and names the broken link. Read-only. `--ask-nodes` adds the per-node systemd and sudo checks |
| `check_squeue.sh` | The queue in one aligned table, whole cluster; `-j <id>` adds node state and reservations |
| `admin_pause-agents.sh` | Stops the watchdog and every node timer, `--resume` puts them back through `install-agent.sh`, `--status` says what is running. Writes nothing to the share, which is what makes it usable when the share is the problem. See [how-to/update-the-deployment.md](../how-to/update-the-deployment.md) |
| `admin_kill-jobs.sh` | Cancels this framework's jobs; `-p` also sets `RUN_JOBS=no`. See [how-to/pause-and-resume.md](../how-to/pause-and-resume.md) |
| `admin_purge-node-benchmarks.sh <nodes>` | Removes `results/<node>` outright. See [how-to/reset-results.md](../how-to/reset-results.md) |
| `check_dmesg.sh <nodes>` | Saves each node's ring buffer under `dmesg-archive/`, and with `--clear --resume` breaks the drain-resume-drain loop a full dmesg causes. Will not clear a node the head node's syslog does not have. See [how-to/archive-and-clear-dmesg.md](../how-to/archive-and-clear-dmesg.md) |
| `check_ib.sh <node>` | Compares the HCAs the host sees against the container's. See [how-to/diagnose-ib-visibility.md](../how-to/diagnose-ib-visibility.md) |
| `build_containers.sh` | Builds the images named on its command line, or `-A` for all. See [how-to/build-containers.md](../how-to/build-containers.md) |
| `build_llmb.sh` | Installs or inspects the optional `llmb-run` capture workspace; its resolved cache can seed `LLM_HF_HOME`. See [how-to/enable-llm-pretrain.md](../how-to/enable-llm-pretrain.md) |

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

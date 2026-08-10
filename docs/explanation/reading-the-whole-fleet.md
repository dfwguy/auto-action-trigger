# Reading the whole fleet at once

`overall_report.sh` answers one question — *what is not working, and what do we
already know about it* — and it is the only report in this tree that crosses the
three sources of truth: the benchmark results under `results/`, the health check
output under `logs/`, and Slurm. This page is why it is shaped the way it is.
What it prints and which flags it takes is
[reference/scripts.md](../reference/scripts.md); running it against a specific
problem is [how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md).

## It is an exception list

`status-check.sh` and `daily-report.sh` both describe the whole fleet: every
node, every column, passing or not. That is the right shape when the question is
"where does everything stand", and the wrong one when the question is "what do I
work on" — a passing cell is a row of output that will never be acted on, and on
a 576-node cluster there are several thousand of them between you and the
fourteen that matter.

So this report prints only what has no pass. A node that clears every column
appears nowhere in it, and a completely clean cluster produces a report that
says so in three lines. That inversion is the whole point, and it has one cost
worth stating plainly: **you cannot tell a healthy fleet from an unconfigured
one by its length.** Both are short. That is what the header line and the
`NOTE:` block above the sections are for — the node count, the column count, the
settings file the run read, and every pause switch that is suppressing work get
printed before anything is judged, so an empty report always carries the
evidence that it was empty for the right reason.

## Grouped and per-node are different questions

The report has both, deliberately, because "what do I fix" and "what is wrong
with *this* node" do not have the same answer:

- **BENCHMARKS and HEALTH CHECKS are grouped.** Nodes that fail the same way for
  the same reason are one line and one node list. Sixty nodes below the same
  bandwidth floor are one problem, and printing them as sixty entries makes it
  read like sixty.
- **NODES is per node.** One block each, carrying everything the tree knows
  about it from every source at once. This is the section that exists because
  the interesting cases are exactly the ones where the sources disagree — a node
  with no result, no drain, no job in the queue and nothing in its trace is a
  different fault from one with all four.

A node therefore appears more than once, in more than one shape. That is not
redundancy; the grouped sections are indexed by the failure and the per-node
section is indexed by the node.

## A prolog drain does not say why

This is the case the report was written for.

When the pre-job check fails, Slurm records that the *prolog* failed and nothing
else. The drain reason reads `Prolog error`, on every node it ever happens to,
forever. It does not name the check, and there is no Slurm query that will
recover it: the check ran on the compute node, wrote its findings to a
node-local path under `RECOVER_PREJOB_LOGS`, and the head node this report runs
on cannot read that path.

What *is* readable is the note `slurm-recovery.sh` leaves behind. When the
recovery looks at such a node it opens that log on the node itself and writes
what it found into the node's trace, which lives on the shared tree:

```
recover note: the pre-job check that drained ink50-dh01-h20-35 failed on [dmesg];
nothing it named is still running, so this is a resume rather than a hold.
```

That line is the only head-node-readable record of why a prolog failed, so the
report greps for it across `results/*/trigger.log` — one `grep` for the fleet,
not one per node — and prints it under the drain reason it explains. The
reasoning behind the note itself, and the pid-and-user matching that decides
whether a rogue process is still there, is
[drain-recovery.md](drain-recovery.md#a-rogue-process-drain-names-its-process).

When there is no such note the report says so, and gives the fan-out line that reads
the node-local log directly. An empty `prolog` line would be indistinguishable
from a node whose prolog never failed, which is the failure mode this whole tree
is built against — see [architecture.md](architecture.md#silence-is-the-enemy).

## Health, read from the files

`health-check.sh` used to read the Slurm drain reason, because that is where
`node_health.sh` writes its verdict. That made it exactly as complete as the
drains behind it, and with the shipped `DRAIN_AFTER_FAILED_HEALTH_CHECK=no`
there are none: every node read as passing, and the script printed a banner
saying so. A banner is a reasonable thing to do about a gap. It is not a
reasonable thing to leave in the report an operator runs to find out what is
broken, and a site running with drains off is the site that most needs the
answer.

So neither report reads Slurm for health. `node_health.sh` decides by diffing
`logs/<node>/<check>` against `valid-config/default/<check>` byte for byte, and
both files are on the shared tree — so the same conclusion can be reached from
the files, whether or not anything ever drained.

The comparison lives in `health-scan.sh`, sourced by `overall_report.sh` and by
`health-check.sh`, and so does the HEALTH block both of them print — one
function, one set of numbers. Two reports that disagree about which nodes are
failing are worse than either of them alone, and that is what a second copy of
this comparison would eventually become.

What drains-off still costs is visible in `sinfo` and nowhere else: nothing was
taken out of the queue. That is what `health-check.sh` says in its banner now.
Slurm keeps one question the files cannot answer — what is drained, and for what
— so `--drained` is a separate report against `sinfo` rather than a filter on
this one.

Two details keep that reproduction honest:

- **Informational checks are excluded.** A check carrying `# informational: yes`
  is recorded and never drained on, because per-rack values cannot match one
  cluster-wide baseline. Including them would report a rack's own IMEX
  configuration as a fault on every node in it. See
  [reference/health-checks.md](../reference/health-checks.md#informational-checks).
- **It is checksums, not `diff`.** One `md5sum` over the baseline and one over
  every `logs/*/*` answers the same question as 38 diffs per node, which on a
  576-node cluster is 21,888 processes. Byte-exact equality is what
  `node_health.sh` tests, so equal checksums are exactly the checks it would not
  have drained on.
- **The comparison is one `awk`, not a bash loop.** That checksum stream is
  21,888 lines, and `while read` around it was 5.3 seconds of an 8.5-second run
  — bash reads a pipe a byte at a time, and the array insert costs again on top.
  `awk` returns the two aggregates already built, per node and per check, so
  bash only ever reads the failures. See
  [what a report costs](#what-a-report-costs).

A check with no baseline entry can never pass and is counted separately rather
than reported as a fleet-wide fault — the fix for those is a new baseline, not
anything on the nodes.

## Slurm is asked three times

Once for the whole fleet, never once per node. A per-node `sinfo` or `squeue` on
576 nodes is 576 round trips to a controller that is also scheduling the sweep,
and the report is meant to be safe to run while the timers are live:

| Call | Answers |
|---|---|
| `sinfo -N -h -o '%N\|%T\|%u\|%H\|%E'` | state, who set the reason, when, and the reason. Reason last: it is free text |
| `squeue -h -o '%i\|%T\|%j\|%u\|%r\|%M\|%N'` | the queue, ours and everybody's |
| `scontrol` | compressing node lists for printing, and expanding another user's job |

Our own jobs need no expansion: they are named `bringup-<node>` and
`burnin-<node>`, so the job maps to a node from its name. Only somebody else's
job carries a nodelist that has to go through `scontrol show hostnames`, and
there are few of those on a cluster in bringup — which is what keeps the
`scontrol` calls bounded by other people's jobs rather than by fleet size.

Losing any of this is not fatal. Each section names the answer it lost rather
than printing a blank, for the same reason the trace exists at all.

## The spread column

`daily-report.sh`'s metric summary carries `n`, `min`, `median`, `mean`, `max`
and `cov` — the coefficient of variation, standard deviation over mean, across
the cells that held a number.

`min` and `max` are single nodes, and a fleet is not usefully described by its
two most extreme members: one dead node drags `min` somewhere the other 2,000
never went, and reading it tells you about that node rather than about the
cluster. `cov` is the whole distribution in one figure, and it is unit-free, so
`nvbandwidth` at GB/s and `llm-pretrain` at milliseconds can be compared for
*tightness* even though their numbers cannot be compared at all.

It is the same measure the per-node gates band on — `VERDICT_MAX_COV_NVBANDWIDTH`
across one node's transfers, `VERDICT_MAX_COV_LLM_SOLO` across one tray's four
GPUs — one level up, across the fleet instead of within a node. That is
deliberate: a number an operator already reads at the node level means the same
thing at the top of the report.

What to do with it:

| `cov` | Reading |
|---|---|
| under ~0.01 | Tight. Every node agrees; a floor set off one node generalises |
| ~0.01–0.05 | Ordinary silicon spread. Read `min` against the floor |
| above ~0.05 | Two populations, not one wide one. Look for a rack, an image or a config that splits the fleet, before treating any single node as an outlier |

The last row is the one that earns the column. A bimodal fleet — most nodes
healthy, a rack of them failing hard — has a `median` that looks perfect and a
`cov` that does not, and the `cov` is the only figure in the block that says so
without reading 2,000 rows.

**It is taken over failing cells too**, like every other statistic in that block
— see the note on `min` in
[reference/scripts.md](../reference/scripts.md#daily-reportsh--per-node-table-with-metrics).
So a fleet with a handful of hard failures reports a `cov` those failures
dominate. That is the intended reading for spotting them; it is the wrong sample
for re-deriving a pass floor, which wants the passing cells only.

## What a report costs

This one crosses every result file, every health log and the whole queue, so it
is the report most able to become something nobody runs. Measured on a 576-node
fixture — 4,608 benchmark cells, 21,888 health logs, a 165 kB trace per node:

| | before | after |
|---|---|---|
| warm, default | 9.1 s | 3.4 s |
| warm, `--full` | 15.4 s | 4.5 s |
| cold, no verdict cache | 25.1 s | 20.3 s |

Three things accounted for nearly all of it, and all three are the same
mistake — **doing per-item work in bash**:

- **The health comparison**, 5.3 s. A `while read` over 21,888 checksums. Now
  one `awk`, above.
- **`wrap_list`**, ~5 s on `--full`. One `awk` plus a process substitution to
  read it back, called about 1,700 times when 576 node blocks print. Now bash,
  writing into an array with no subprocess at all. It is a formatting primitive
  shared with `health-check.sh`, so `tests/report-format-test.sh` keeps it
  equivalent to the awk it replaced rather than trusting the rewrite.
- **Ranking the node blocks**, 1.1 s. `$(node_rank "$node")` is a fork per node;
  it sets a variable now, the same way `verdict()` does and for the same reason.

What is left is close to the floor for the data: `md5sum` over 21,888 files
(0.45 s), one `grep` over 97 MB of traces (0.23 s), and the verdict scan itself.

The cold column is the one that does not improve much, and should not: it is
`verdict-scan.sh` judging every cell from its file, which is already parallel,
already cached, and shared with the other two reports. Paying it once after
results change is the design — see
[verdicts-and-the-cache.md](verdicts-and-the-cache.md#the-verdict-cache).

The general rule this leaves behind: **anything that touches every node, every
cell or every log file belongs in one `awk`, `grep` or `find`, not in a bash
loop.** Bash is for assembling what those return.

## The order node blocks come in

The per-node section is the one that grows with the cluster, so it is capped by
default and `--full` lifts the cap. That makes the *order* load-bearing: what
survives the cap has to be what nobody else will explain.

Blocks are ranked worst first, on how much of the node's story is missing from
the rest of the report rather than on how bad the node is:

| Rank | Node | Why it leads |
|---|---|---|
| 6 | down, failed or unknown to Slurm | It cannot run anything, and no benchmark verdict will say that |
| 5 | drained, maintenance or reserved | Same, and the reason is often the whole answer |
| 4 | failing health checks | The grouped section names the check; only here does one node's full set appear |
| 3 | idle, nothing queued or running | The quiet fault: nothing wrong with it and no work going to it |
| 2 | another user's job on it | Explains the absence, and is not a fault |
| 1 | our own job on it | Working as intended; outstanding columns are just not done yet |

Rank 3 above rank 2 and 1 is the deliberate part. A node with a job on it has a
reason for its outstanding columns and will clear them on its own; a node with
nothing running and nothing queued will stay exactly as it is until somebody
notices, and that is the node an elided report must not drop.

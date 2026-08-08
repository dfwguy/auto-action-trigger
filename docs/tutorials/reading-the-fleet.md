# Reading the state of the fleet

Three reports, and they answer three different questions. Run in the wrong
order they contradict each other; run in the right order each one raises the
question the next one answers.

There is a fourth, `overall_report.sh`, which reads all three sources at once
and prints only what has no pass. It is the one to reach for when the question
is "what do I work on"; the three below are how you learn what its sections
mean, so read them first. It has its own page in
[reference/scripts.md](../reference/scripts.md#overall_reportsh--everything-without-a-pass).

By the end of this you will know which to reach for, why two of them can
legitimately disagree about the same node, and — the part that matters most —
which numbers in them are trustworthy and which are only as good as the
configuration behind them.

Everything here is **read-only**. Pick a cluster with results on disk:

```bash
cd /home/cmods/bringup
```

## The three questions

| Report | Answers | Reads |
|---|---|---|
| `status-check.sh` | What state is every benchmark in? | `results/` + `squeue` |
| `daily-report.sh` | What are the numbers? | `results/` + `sinfo` |
| `health-check.sh` | What is wrong that is not a benchmark? | Slurm drain reasons |
| `overall_report.sh` | What has no pass, and what do we know about it? | all three, plus each node's trace |

Note the third column, because it is where all the surprises come from. They do
not read the same inputs, so they can be simultaneously right and different.

## 1. `status-check.sh` — what state is everything in?

```bash
bash status-check.sh
```

One line per node per benchmark column, grouped by identical status so a rack
behaving the same way is one block rather than eighteen lines. The grouping is
`dshbak`, from `pdsh` — if it is not installed the script says so and prints
ungrouped rather than silently printing nothing.

Each line reads `node: column: status`, with a reason appended when there is one:

```
allreduce-nonvlink: FAIL -- collective carried over TCP
```

Six statuses. Learn these two facts about them and the rest follows:

- **`FAIL` covers two different things** — the job reported it could not run,
  *or* it ran and the gate rejected the output. Which one is in the result file,
  not here.
- **`RETRY` is not `NOT_RUN`.** `RETRY` means the last attempt was archived and
  another is queued; `NOT_RUN` means nothing has ever been attempted. They used
  to be one status, and merging them reported a column with a history of
  failures as one that had never been tried.

Now narrow it. The node pattern is a prefix unless you spell out a glob:

```bash
bash status-check.sh ink50-dh01-h20        # the whole rack
```

And the test filter, which behaves deliberately differently:

```bash
bash status-check.sh -t allreduce
```

**`-t` does not append a `*` the way the node pattern does.** Benchmark names
are prefixes of each other — `allreduce` and `allreduce-nonvlink` — so an
implicit prefix match would quietly drag the nonvlink pair into every request
for `allreduce`. Spell the glob out when you want it:

```bash
bash status-check.sh -t 'allreduce*'       # both
bash status-check.sh -t '*nonvlink'        # the nonvlink pair
```

Try a name that does not exist:

```bash
bash status-check.sh -t typo
```

It exits non-zero and lists what *is* active, rather than printing an empty
report. That is deliberate and worth internalising early: **an empty report and
a clean cluster look identical**, so anywhere that distinction can be made, it
is.

## 2. `daily-report.sh` — what are the numbers?

```bash
bash daily-report.sh | head -20
```

One row per node. The first column after the node name is its **Slurm state**,
and that column is the reason this report exists separately from the last one.

Look at a row with a `NOT_RUN` in it. On an `idle` node that is a question — why
has nothing run? On a node that has been `drain` all week it is not a mystery at
all: nothing could be scheduled onto it. Same cell, completely different
meaning, and only this report puts the two next to each other.

Now the thing people misread. **A cell holds a number, not a verdict.**

A job that produced a figure shows the figure — GB/s for the NCCL jobs, Gflops
for HPL — *whatever the gate made of it*. A status word appears only when there
was no number to print: the job never ran, never finished, or died before
printing a result.

So a cell reading `41.2` might be a pass or a fail, and this report will not
tell you which in that cell. What tells you is the block at the bottom.

Scroll down to the summary. It is on **stderr**, so it is still on your screen
even if you redirect the table — and it stays out of any file you export.

```bash
bash daily-report.sh > /dev/null      # summary only
```

One thing to notice while you do that: the summary you just got is raw
tab-separated rather than the aligned columns you saw a moment ago. That is the
report's single layout rule doing its job — **aligned only for TSV at a
terminal, raw separated rows for anything else** — and "anything else" includes
sending the table to `/dev/null`. Run it without the redirect to read it
aligned; use the redirect when you want the summary alone.

Five blocks. The two worth learning now:

**`job (metric)`** — `n`, `min`, `median`, `mean`, `max` per job, over the cells
that hold a number. Per job rather than pooled, because Gflops, GB/s and MB/s
share a table but not a scale. **Failing runs are included**, so the `min` is
the worst node on the cluster and not the worst node that passed.

**`job (pass/fail)`** — cells per job counted by status. This is the verdict
block, and it is the only summary a pass/fail job gets at all: `dcgmi-r3`,
`stressapptest` and `memtester` judge a node without producing a figure, so
they have no row in the metric block.

That split is the whole shape of this report: **numbers above, verdicts below.**

## 3. Why the two reports disagree

Run both against a node with a benchmark running right now, if you have one:

```bash
bash status-check.sh <node> | grep -i running
bash daily-report.sh <node>
```

`status-check.sh` can say `RUNNING`. `daily-report.sh` never does. Neither is
wrong.

`status-check.sh` makes one cluster-wide `squeue` call and uses it to reclassify
the column a live job is writing — without it, a benchmark mid-run is a partial
file with no end marker, which reads exactly like a job that died. `RUNNING` is
live state, and it is why that report needs `squeue` at all.

`daily-report.sh` reads `sinfo`, not `squeue`. It knows the node's state but not
what is executing on it, so it cannot tell a live partial file from a dead one
and does not claim to. It also does not report `RETRY`, because it does not look
at the archives.

**The general rule this teaches: when two views of this system disagree, check
what each one read before assuming one is broken.** That is true of the reports,
and it is true of the host-versus-container HCA lists that cost this project
weeks.

## 4. `health-check.sh` — what is wrong that is not a benchmark?

```bash
bash health-check.sh
```

This one reads **only Slurm drain reasons**. It contacts no node and re-runs
nothing; it reports what the last health run concluded.

Nodes are grouped by the *exact set* of checks they failed, largest group first.
That grouping is the point: sixty nodes failing the same thirty-eight checks are
one out-of-spec image with one fix, and printing them as thirty-eight check
lines over sixty node lists reads as 2,280 incidents.

The report ends by naming one node to diagnose:

```
Why a node failed:  bash sync-check.sh ink50-dh01-h20-36
```

**One node per group is enough.** The rest of the group failed the same checks;
sixty copies of one diff buries the answer.

Now the roll-up:

```bash
bash health-check.sh --summary
```

The same failures, cut the other way: one line per check with every node under
it, so you can see how far a single fix reaches. It ends with the nodes that
have no `logs/<node>` at all. **A node that has never run the health checks is
not a node that passed**, and is not counted as one.

## 5. Read the banners before you trust the report

This is the step people skip, and it is the one that makes the other four
meaningful. Look at the top of that last output.

If drains are off — which is how the framework ships — you will see:

```
NOTE: DRAIN_AFTER_FAILED_HEALTH_CHECK=no in SETTINGS
      No drain was set, so jobs are still being scheduled onto 60 of the
      64 failing nodes below.
```

The failures themselves are reported either way — both reports read
`logs/<node>` rather than the Slurm reason field. What that banner tells you is
that Slurm does not know: those nodes are in the queue and taking work right now.
`bash health-check.sh --drained` is the same report narrowed to the ones that
have actually been taken out.

Two other banners work the same way, and all three exist for one reason — **a
report that cannot change looks exactly like a cluster that has settled**:

| Banner | Means |
|---|---|
| `WARNING: No baseline` | `valid-config/default` does not resolve, so there is nothing to compare against and no failure can be reported. An empty report, on a cluster nobody has checked |
| `PAUSE_HEALTH_CHECKS=yes` | Nothing re-runs; this is a snapshot of whenever the pause went on |
| `PAUSE_JOBS=yes` (in `status-check.sh`) | No benchmarks are being submitted, so nothing below will change |

Check for a fourth, which is not a banner but a line in the body:

```
No baseline in valid-config/default — 3 checks can never pass:
```

A check added after the last `set-valid-default.sh` run has no baseline entry,
so it fails on every node forever. The fix is a new baseline, not anything on
the nodes.

## 6. Putting them in order

Run them in this order, because each answers a question the previous one raises:

```bash
bash health-check.sh --summary     # 1. is the hardware even in spec?
bash status-check.sh               # 2. what state are the benchmarks in?
bash daily-report.sh               # 3. what are the numbers, and the spread?
bash trigger-log.sh                # 4. why is nothing happening?
```

**Health checks first**, because they gate everything downstream. A node with
the wrong BIOS or a dead HCA will fail benchmarks for reasons that have nothing
to do with the benchmark, and diagnosing that from a bandwidth number is hours
wasted.

**`trigger-log.sh` last, and only if the first three are suspiciously empty.**
It answers "why is nothing being produced", which is a different question from
all of the above — that is
[understanding-the-triggers.md](understanding-the-triggers.md).

## What a good site looks like

Now you can read one. In rough order, at a new site:

1. **`health-check.sh` is clean, or its groups are understood.** Get the
   baseline right first.
2. **`status-check.sh` shows columns filling in**, not a wall of `NOT_RUN`. A
   wall of `NOT_RUN` with no trace activity is a chain problem, not a hardware
   one.
3. **`daily-report.sh` numbers cluster tightly.** The *spread* across nominally
   identical nodes matters more than any single value. A fleet where every node
   lands in the same narrow band is healthy even before you have confirmed the
   band is right; a fleet scattered across a 3× range has something wrong
   regardless of how good the best node looks.
4. **The outliers are few and named.** A handful of nodes below a floor is a
   hardware finding. *Every* node below a floor is the floor being wrong for
   this platform.

Point 4 is the one that has cost the most time here, in both directions, and it
is worth carrying: **the framework fails closed**, so a bad rule condemns the
whole fleet and looks exactly like a catastrophic hardware event.

## Where to go next

| Next | Guide |
|------|-------|
| Turn a report into a node list you can act on | [how-to/get-a-node-list.md](../how-to/get-a-node-list.md) |
| Find the slow node when nothing has failed | [how-to/find-outlier-nodes.md](../how-to/find-outlier-nodes.md) |
| Get a report into a spreadsheet | [how-to/export-a-report.md](../how-to/export-a-report.md) |
| A node failed and you need the device | [how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md) |
| Every flag and what every column means | [reference/scripts.md](../reference/scripts.md) |
| Why a verdict is derived on every read | [explanation/verdicts-and-the-cache.md](../explanation/verdicts-and-the-cache.md) |

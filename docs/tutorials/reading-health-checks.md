# Reading the health checks

`health-check.sh` has three views worth learning, and each one answers a
question the other two cannot. By the end of this you will know which to reach
for, and — the part that matters — why a node can be perfectly healthy in one of
them and a problem in another without either being wrong.

This tutorial skips the default grouped report. It is the right thing to run
when you have no idea what is wrong, but once you know the three views below you
will reach for them instead: they are complete where the default elides, and
each one is cut along an axis you can act on.

Everything here is **read-only**. Nothing is contacted, nothing is re-run, and
no drain is set or cleared. Pick a cluster with health logs on disk:

```bash
cd /home/cmods/bringup
```

## What the checks are, in one paragraph

Every node runs 38 checks on a timer and writes one file per check into
`logs/<node>/`. A check "fails" when its file does not match
`valid-config/default/<check>` byte for byte — the same comparison
`node_health.sh` drains on. There is no cleverness in the verdict: it is a file
comparison, and the baseline is a copy of one node somebody validated. Hold onto
that, because the third view below is where it matters.

## 1. `--drained` — what is out of the queue?

Start here, because it is the only one of the three that answers a question
about *Slurm* rather than about the logs:

```bash
bash health-check.sh --drained
```

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

One line per distinct reason, largest first, with the node list under it.
`sinfo -R` answers the same question one node at a time, and a rack powered off
by CMDaemon reads there as eighteen separate incidents. Here it is one line, and
it stays one line however many racks get added — which is exactly what makes
that last entry, a group of one, worth reading.

Three things to notice:

**The state is part of the grouping, not decoration.** `down` and `drained` over
the same text are two different situations, so they are two lines. A node that
is down with nothing recorded gets its own group rather than being folded in
with the drains.

**`(logs now match)` is a repaired node nobody resumed.** The drain says `bios`,
but `logs/<node>/bios` matches the baseline now. Somebody fixed it and no
process put it back in the queue. See [a drain the logs no longer
support](../how-to/manage-drains.md#a-drain-the-logs-no-longer-support).

**Nothing here is a health verdict.** This view reads the Slurm reason field and
almost nothing else. An operator drain (`admin: waiting on RMA`) and a health
drain sit side by side because to the scheduler they are the same thing: a node
not taking work.

The node lists are compressed into ranges deliberately — they paste straight
into `scontrol`, `pdsh -R ssh -w`, or the `--refresh` flag.

## 2. `--summary` — what is broken, and how far does one fix reach?

Now the other half. This one ignores Slurm entirely and reads the logs:

```bash
bash health-check.sh --summary
```

```
── HEALTH CHECKS ───────────────────────────────────────────
3 checks failing on 60 nodes (logs/<node> against valid-config/default)

    nvlinks                   60 nodes
      ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34]
    ib-firmware                8 nodes
      ink50-dh01-h01-[11-18]
```

One line per failing check with every node under it. Nothing elides here — this
is the complete list, which is what makes it the one to run when you are about
to act rather than just look.

Read it as **"how far does each fix reach"**. A check failing on 60 nodes is one
image problem with one fix; a check failing on 3 is a hardware finding. The
default report cuts the same data the other way, by grouping nodes that failed
the *same set* of checks, and answers "what do I fix on this node" instead.

Two things this view is careful about, both of which exist because an empty
report and a healthy cluster look identical:

**A node with no `logs/<node>` at all is listed separately as never checked.**
It has not passed. It is not counted as passing.

**A check with no baseline entry is called out.** A check added since the last
`set-valid-default.sh` run has nothing to compare against, so it fails on every
node forever. The fix is a new baseline, not anything on the nodes.

Now split it by what the scheduler thinks:

```bash
bash health-check.sh --by-state
```

```
3 checks failing on 193 nodes, by Slurm state (logs/<node> against valid-config/default)

Slurm state: idle — 97 nodes
    nvlinks                   97 nodes
      ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34]

Slurm state: drained — 96 nodes
    nvlinks                   96 nodes
      ink50-dh01-h07-[11-36]
```

This is the view that connects the first two. The flat roll-up counts a node
that is already drained the same as one still taking work, so `nvlinks — 193
nodes` cannot tell you how much of that a drain would actually take out of the
queue. This can: 97 of those nodes are `idle` and being scheduled onto **right
now**.

That gap is the normal case, not an error. The framework ships with
`DRAIN_AFTER_FAILED_HEALTH_CHECK=no`, so failures are reported from the logs
while Slurm is never told. When that is on you will see a banner saying so, and
it is worth reading before you trust any count on the page.

## 3. `--individual` — what values does the fleet actually carry?

The first two views both start from a verdict: pass or fail against the
baseline. This one does not judge at all. It takes a **check name** and groups
the nodes whose file for that check is byte-for-byte identical:

```bash
bash health-check.sh --individual ib-firmware
```

```
ib-firmware — 2003 nodes

1998 nodes
  ink50-dh01-h01-[11-36],ink50-dh01-h02-[11-34],...
########INFO: Check IB FW (Expected: All nodes have the same FW version)
             /sys/class/infiniband/mlx5_0/fw_ver     40.48.1126
             /sys/class/infiniband/mlx5_1/fw_ver     40.48.1126

4 nodes
  ink50-dh01-h03-[11-14]
########INFO: Check IB FW (Expected: All nodes have the same FW version)
             /sys/class/infiniband/mlx5_0/fw_ver     40.47.2628
             /sys/class/infiniband/mlx5_1/fw_ver     40.47.2628

1 node
  ink50-dh01-h09-22
########INFO: Check IB FW (Expected: All nodes have the same FW version)
             /sys/class/infiniband/mlx5_0/fw_ver     32.47.2526
```

Largest group first, so the value most of the fleet carries leads and the
outliers fall to the bottom where you can see them.

**Why this is not just `--summary` with more words.** `--summary` tells you
*which nodes disagree with the baseline*. This tells you *what every node
actually has*, including all the ones that pass. Those are different questions,
and the second one is the one you need when:

- **The baseline itself is suspect.** If `valid-config/default` was captured
  from the one node with the odd firmware, `--summary` will confidently report
  1998 failures. `--individual` shows you a 1998-node group and a 4-node group
  and makes the mistake obvious in a second.
- **Nothing is failing but something is off.** A check can pass on every node
  and still show two firmware versions, if the check does not compare the field
  that differs. Only this view surfaces that.
- **You need the actual value.** "What firmware are we on" is not a question the
  other two views can answer at all.

The node pattern is the **second** argument here, because the first one is the
check name:

```bash
bash health-check.sh --individual ib-firmware ink50-dh01-h01
```

Try it against a check you expect to be uniform, then one you expect to vary:

```bash
bash health-check.sh --individual bios
bash health-check.sh --individual nvlinks
```

A single group means the fleet agrees, whatever the baseline says about it. Many
small groups means it does not, and the group sizes tell you which value is the
anomaly. Check names are the health check files without their number prefix —
`ls health-checks/$HEALTHCHECKS/` lists them, and
[reference/health-checks.md](../reference/health-checks.md#the-check-list) has
the full table.

This view reads no Slurm state at all, so nothing about drains can appear in it.

## 4. Putting them in order

The three views chain, and the order is the same one you would ask the questions
in out loud:

```bash
bash health-check.sh --summary       # 1. what is broken, and how far does it reach?
bash health-check.sh --by-state      # 2. how much of that is still taking work?
bash health-check.sh --drained       # 3. what is out of the queue, and why?
bash health-check.sh --individual <check>   # 4. what value is actually on the nodes?
```

Steps 1 and 3 read **different sources** — the logs and the Slurm reason field —
so they can disagree completely and both be right. A node failing `nvlinks` with
drains off appears in the first and not the third. A node drained by an operator
appears in the third and not the first. Step 2 is the bridge, and step 4 is what
you run when a number in any of the others looks wrong.

The general rule, and it is worth carrying past this page: **when two views of
this system disagree, check what each one read before assuming one is broken.**

## 5. Diagnosing one node

The three views above all stop at *which check* failed. To see *what is
different*, diff the node against the baseline:

```bash
bash health-check.sh --diff ink50-dh01-h01-11
```

```
ink50-dh01-h01-11  (drained: nvlinks)
  <  this node
  >  baseline (ink50-dh01-h05-22)

--- nvlinks
2c2
< links 0
---
> links 228

--- ib-firmware
2c2
< fw 40.47.2628
---
> fw 40.48.1126

2 of 38 checks differ
```

**Read the diff direction before you act on it.** `<` is this node and `>` is
the baseline. Backwards, `< 0` against `> 228` looks like the baseline is broken,
and "fixing" the baseline turns one bad node into sixty bad nodes.

**The checks it diffs come from the logs, not from the drain reason.** That
distinction is the whole reason this lives here rather than in a separate tool.
The drain on the first line is *context* — it is what Slurm was told — and the
diff below it is what is actually true. In the example the node is drained for
`nvlinks`, but `ib-firmware` broke afterwards and no drain ever mentioned it.
And with `DRAIN_AFTER_FAILED_HEALTH_CHECK=no` there is no reason at all, so a
tool reading the reason field would have nothing to say about a node failing two
checks.

Reach for `--all` when the baseline itself is in question:

```bash
bash health-check.sh --diff --all ink50-dh01-h01-11
```

That diffs every gated check rather than only the failing ones, and names the
matching ones at the end. It pairs with `--individual` from step 3: if that
showed your node in a group of 1998 rather than a group of 4, the node is fine
and the baseline is the outlier.

**One node per group is enough.** The rest of the group failed the same checks,
and sixty copies of one diff buries the answer.

## 6. Verifying a fix

This is the loop that matters, and it has four steps. Skipping any of them
leaves you believing something you have not checked.

The checks run on a timer — `HEALTH_INTERVAL_HOURS` — so a node you just
repaired keeps reporting its old result until that timer comes round. Nothing
about fixing the hardware tells the framework to look again.

### Step 1 — queue the re-check

Paste the node list straight out of any view above:

```bash
bash health-check.sh --refresh 'ink50-dh01-h01-[11-18]'
```

```
Refresh queued for ink50-dh01-h01-11
Refresh queued for ink50-dh01-h01-12
```

It takes node names and Slurm nodelists, is repeatable, and **prints no report**
— the re-check it just asked for has not happened yet, so there would be nothing
new to show. All it does is set a sentinel in `logs/<node>/`.

### Step 2 — wait for it to actually run

The node picks the sentinel up on its next monitoring cycle. Confirm it did
rather than assuming:

```bash
bash health-check.sh --explain 'ink50-dh01-h01-[11-18]'
```

```
NODE                         LAST RUN             OUTCOME  NEXT DUE
ink50-dh01-h01-11            2026-08-08 04:12:31  failed   refresh queued
ink50-dh01-h01-12            2026-08-08 09:38:04  clean    in 96m
```

`refresh queued` means it is still waiting. Once `LAST RUN` moves to a time
after your repair, the result below is about the fixed node. If a node sits at
`refresh queued` for hours, or reads `overdue`, the health trigger is not
reaching it — that is a different problem, and
[explanation/health-cadence.md](../explanation/health-cadence.md) covers it.

### Step 3 — confirm the verdict changed

Both views, because they answer different halves:

```bash
bash health-check.sh --summary 'ink50-dh01-h01-[11-18]'
bash health-check.sh --individual ib-firmware 'ink50-dh01-h01-[11-18]'
```

The first says whether it now passes. The second says **what value it landed
on**, which is the one to trust — a node can stop failing because somebody
widened the baseline rather than because anything was fixed, and only the second
view can tell those apart. Confirm the repaired nodes moved into the same group
as the rest of the fleet.

If the node was drained for the failure, it does not come back on its own in
every case. `--drained` will still list it:

```bash
scontrol update NodeName=ink50-dh01-h01-11 State=RESUME
```

Which drains clear themselves and which need this is in
[how-to/manage-drains.md](../how-to/manage-drains.md#which-drains-will-clear-themselves).

### Step 4 — prove it under load

A passing health check says the node's *configuration* matches. It says nothing
about whether the hardware performs. For anything you physically touched — a
reseated HCA, a replaced GPU, a firmware flash — run a benchmark before putting
the node back in the fleet.

The supported way is `launch_job.sh --test`, because it goes through the same
gates and writes its result where the reports read it:

```bash
pdsh -R ssh -w ink50-dh01-h01-11 '/home/cmods/bringup/actions/launch_job.sh -t allreduce -v'
```

`--test` runs that job whether or not `BENCHMARKS` names it, implies `--force`
and `--all`, and **drains nothing** however it turns out — a job run
deliberately must not be able to take a node out of service. Full behaviour in
[how-to/run-a-job-by-hand.md](../how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list).

For a single repaired node, `hpl` and `cublasmatmul` are the remediation jobs
meant to be run by hand. Submit one straight from the job directory:

```bash
cd /home/cmods/bringup
source settings.sh

node=ink50-dh01-h01-11
sbatch -w "$node" --nice=0 \
       --export=ALL,BRINGUP_HOME="$BRINGUP_HOME",CONTAINER_DIR="$CONTAINER_DIR" \
       --output="$BRINGUP_HOME/results/$node/cublasmatmul.txt" \
       "$JOBS_DIR/cublasmatmul.sbatch"
```

Three things carry weight there. **`source settings.sh`** is what makes the rest
of it the site's own paths rather than typed ones. **`--export`** hands the job
the paths it cannot work out for itself — a batch script runs from Slurm's spool
copy, so it can neither read `SETTINGS` nor find the tree; without them the job
stops and says which variable was missing. **`--output` is what puts the result
where the reports look** — the `-o` line inside the job file is deliberately
disabled, because `launch_job.sh` supplies the path per node. Without it the
output lands in `slurm-<jobid>.out` in your working directory and no report will
ever see it. (`--nice=0` puts it at the front of the queue; the sweep sits at
`20`, and that tier is left empty for exactly this.)

Submitting a job file yourself has a few more consequences than fit here —
[how-to/submit-a-job-file-directly.md](../how-to/submit-a-job-file-directly.md)
has the whole of it, including which jobs need which variables.

Then read the verdict rather than the raw file:

```bash
bash status-check.sh -t cublasmatmul ink50-dh01-h01-11
```

Only now is the node verified: the configuration matches the baseline *and* it
produced a number the gate accepts.

## Where to go next

| Next | Guide |
|------|-------|
| The other three fleet reports and how they interact | [reading-the-fleet.md](reading-the-fleet.md) |
| Turn any of these into a node list you can act on | [how-to/get-a-node-list.md](../how-to/get-a-node-list.md) |
| Turn the drain switches on, and read what drained | [how-to/manage-drains.md](../how-to/manage-drains.md) |
| Add a check, or set a new baseline | [how-to/add-a-health-check-set.md](../how-to/add-a-health-check-set.md) |
| A node failed and you need the device | [how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md) |
| Every flag, and what every column means | [reference/scripts.md](../reference/scripts.md#health-checksh--cluster-wide-health-summary) |
| All 38 checks and the check file format | [reference/health-checks.md](../reference/health-checks.md) |

# Work out why nothing is running

Two scripts, and **the order matters**. `trigger-log.sh` reads the record the
sequencer already wrote; `trigger-debug.sh` inspects the configuration that
should be producing it. Read the record first — it tells you which of the two
failures you have, and they are indistinguishable from the outside.

Fresh traces settle it on their own. Every gate the sequencer evaluates writes a
line to `results/<node>/trigger.log` before it stops, so a log written this
cycle means BCM fired, the action ran and the script reached a decision — the
chain is intact by definition, and whatever is holding the cluster is a gate
that has already named itself. There is nothing for `trigger-debug.sh` to find
in that case; it answers the other one, where the traces are stale, nothing is
writing them, and the question is which link between BCM and `sbatch` is broken.

## 1. Read the traces

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
5. **Health-check side** — the same three questions as sections 1 and 2, for the
   other trigger. Nodes with a `results/<node>` but no `logs/<node>`:
   `node_health.sh` never ran there, so the node never left DOWN and no
   benchmark could be scheduled onto it — a stuck bringup with a perfectly
   healthy sequencer, because the sequencer is not the thing that is stuck.
   Then whether each node's `health.log` is being written at all, and what its
   last cycle decided. A stale `health.log` beside a fresh `trigger.log` is one
   trigger failing while the other works, which nothing else in this tree can
   show you.

Read-only, and `-w`/`-s` only widen or narrow what it reports. What each line
means is [reference/trace-lines.md](../reference/trace-lines.md).

## 2. If the traces are stale, walk the chain

```bash
bash trigger-debug.sh                 # whole cluster
bash trigger-debug.sh ink50-dh01-h20  # one rack
```

Walks the chain from BCM down to `sbatch` and names the broken link: action
registered, trigger enabled *and* with its action actually bound, script
present, the last decision each node's sequencer made, and result-path
ownership. Read-only.

## 3. Ask one node directly

Rather than waiting for a monitoring cycle:

```bash
pdsh -R ssh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --explain'
```

`--explain` prints every gate the sequencer evaluates and the `sbatch` commands
it would issue, as a dry run — nothing is submitted, drained, or archived, so it
is safe while the trigger is live, and it reads through a pause.

The health runner takes the same flags, and answers the other half of "nothing
is happening on this node":

```bash
pdsh -R ssh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/node_health.sh --explain'
bash health-check.sh --explain ink50-dh01-h20      # or, from the head node
```

`health-check.sh --explain` needs no node access: it reads the stamps and says
when each node is next due. A node reading `overdue` there is one
`NodeHealthTrigger` is not reaching. See
[explanation/health-cadence.md](../explanation/health-cadence.md).

A `backing off:` line there is a job deliberately waiting longer than usual
because it has failed repeatedly — it says how much of the window is left, and
`--force` ignores it. See
[explanation/sequencing.md#backing-off-a-job-that-keeps-failing](../explanation/sequencing.md#backing-off-a-job-that-keeps-failing).

To make it act rather than report, see
[run-a-job-by-hand.md](run-a-job-by-hand.md).

## A queue full of pending jobs

The opposite symptom, and usually not a fault. The sweep submits one job per
node, so a fleet mid-sweep holds on the order of one pending job per node, and
anything large in the queue — a multi-node benchmark, somebody else's training
run, *or one of ours* — keeps them there. A big job that cannot start yet is
given a start reservation, and a single-node job is only backfilled ahead of it
if it would finish before that reservation opens, so ours sit at
`ReqNodeNotAvail, May be reserved for other job` with nothing drained and
nothing broken.

Slurm assigns no node to a pending job, so `%N` is empty and the node it wants
is the job name's suffix, or `%n`:

```bash
squeue -t PENDING -o '%.10i %24j %20n %44r %S' | grep -E 'bringup-|burnin-'
squeue --start -o '%.10i %24j %20n %S'            # when the backfiller expects to start them
squeue -w ink50-dh01-h20-11 -o '%.10i %.10u %.9T %j'   # who is holding the node one of them wants
```

The sequencer treats this as legitimate and says so: queued behind a foreign job
is left alone, and its `trigger.log` line names the reason.

`launch failed requeued held` in the same column is a different state and is
worth reading separately — a held job sits at priority 0 and never starts, so it
will not clear when the queue drains. The sequencer cancels those and resubmits,
but only once the marker goes stale, which is `INFLIGHT_GRACE_MINUTES` after
submission. One outliving that window by a good margin is a real
problem; one inside it is the mechanism working. See
[explanation/sequencing.md#when-a-marker-goes-stale](../explanation/sequencing.md#when-a-marker-goes-stale).

A held job that is *not* named `bringup-*` or `burnin-*` is nobody's to clear
automatically and will sit at priority 0 indefinitely:
[release-a-held-job.md](release-a-held-job.md).

## Reading the queue

```bash
bash check_squeue.sh                 # every job: state, nodes, start time, reason
bash check_squeue.sh -j 121918       # one job, with what the queue line leaves out
```

The plain run is `squeue` in one aligned table, over the whole cluster rather
than our jobs alone — a job of ours waiting is usually waiting on somebody
else's.

`-j` exists because the reason field names a *condition* and never the nodes
behind it: `ReqNodeNotAvail, May be reserved for other job` is true of a job
held by a drained node and of one held by a maintenance reservation, and the two
are acted on differently. So `-j` reads the job's nodes — its allocation once
running, its requested list while pending — and prints each node's state and
drain reason, then the running jobs holding them, then every reservation whose
node list overlaps them. A drained node in that table is ours to fix; a
reservation covering the same nodes means the job is waiting by policy and
nothing is broken.

The third case is the one the first two do not cover, and it is the common one.
A node reported `allocated` with no drain reason and no reservation is working
perfectly — it is simply running somebody else's job, and `Resources` in the
reason column is Slurm saying so without naming the job. That reads as a fault
and is not one, so the queue is scanned for running jobs whose allocation
intersects ours and each is printed with its time remaining. A pending job of
ours behind a 90-node sweep with four hours left needs no action; the same job
behind one that should have ended an hour ago is a different problem, and the
time-left column is what separates them.

Blocking jobs and reservations are both matched by expanding the node lists with
`scontrol show hostnames` and intersecting them, rather than by string-matching
the range expressions, which do not have to be written the same way for the same
nodes. The job under inspection is excluded from its own blocker list — a
running job overlaps itself on every node.

The queue line is printed last so the table is the last thing on screen either
way, and a job id no longer in the queue is reported as such — Slurm keeps a
finished job for `MinJobAge` only, after which `sacct -j` is the place to look.

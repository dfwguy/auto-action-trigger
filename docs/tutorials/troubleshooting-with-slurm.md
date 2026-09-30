# Reading the fleet through Slurm

This teaches you to move between the two places a node's story is written down:
**Slurm**, which knows the node's state and what it is running, and
**`results/`**, which knows what came out of it. Neither half is enough on its
own, and most of the time lost here is spent reading one of them without the
other.

Everything below is **read-only**. Nothing you type will drain a node, cancel a
job or change a result — so do this on a live cluster, on a node that is
working, before you need it on one that is not.

You need a cluster with the framework running and results on disk. Pick one node
and use it throughout. Substitute it for `$N`:

```bash
N=ink50-dh01-h20-11        # a node with results under results/<node>
cd /cluster/bringup
```

## 1. What Slurm thinks of the node

Start here every time, because every other question depends on the answer:

```bash
sinfo -n "$N" -o '%T %E'
```

Two fields. The **state** is one of `idle`, `alloc`, `mix`, `drain`, `drng`,
`down`; the **reason** is free text, and is empty unless the node is drained or
down. On a healthy idle node you get `idle` and `none`.

The state alone does not tell you whether the framework can use the node. That
is the reason field's job, and it is the single most information-dense string in
this system. Read it now even if it is empty — you are learning where it lives.

Widen to the whole fleet:

```bash
sinfo -R
```

One row per drained node, with who set it and when. On a working cluster this is
often long, and that is normal — most of it is Slurm draining nodes for things
that are not the node's fault, which is what step 4 is about.

## 2. Whose drain is it?

This is the distinction the whole framework is built around, and you can read it
straight off the reason string. Look for the word `auto-retry`:

```bash
sinfo -R | grep auto-retry
```

Anything carrying that marker is **ours** — the sequencer drained the node
because a benchmark failed, and the sequencer will clear it itself when the
benchmark passes. Resuming one by hand only starts the next sweep sooner.

Anything **not** carrying it is either Slurm's own or a person's, and the
framework will neither clear it nor queue work behind it. That asymmetry is
deliberate: a node somebody took out of service and a node Slurm drained over a
lost epilog race look identical in `sinfo`, and putting the first one back
silently is the worst thing this code could do.

Now look at the reasons that are *not* ours:

```bash
sinfo -R | grep -v auto-retry
```

You will typically see a mix of prose (`waiting on RMA`, `BF3 TEST BY AIC` — a
person) and machine text (`Prolog error`, `Not responding`, `batch job complete
failure` — Slurm talking to itself). Learning to tell those apart by eye is most
of what step 4 automates.

## 3. Is anything of ours on the node right now?

The framework keeps at most **one** job per node out at a time, under a name
built from the node:

```bash
squeue -n "bringup-$N"
squeue -n "burnin-$N"
```

Usually both are empty — a node spends most of its time between jobs. If one has
a row, note the state: `R` is running, `PD` is pending, and a pending job has an
empty `NODELIST` column, because **Slurm assigns no node to a pending job**. The
node it wants is in the job's name, which is why the name carries the hostname.

The framework's own record of the same fact is a file:

```bash
cat "results/$N/.in-flight"
```

Tab separated: job id, job name, run number, total runs, submit epoch. Absent
means no job is out. That file exists so the node can answer "have I got work
out" without asking the controller — across a few hundred nodes every minute,
asking `squeue` was the expensive part.

Compare the two. They should agree. When they disagree, the file is the thing
that gets repaired, and the trace in step 6 will say so.

Now the whole queue, ours and everyone else's:

```bash
bash check_squeue.sh
```

A job of ours waiting is usually waiting on somebody else's.

## 4. When the queue line does not explain itself

Pick any job id from that table — one of ours if there is one, anyone's
otherwise — and ask about it specifically:

```bash
bash check_squeue.sh -j <jobid>
```

This exists because of a specific gap. The queue's reason field names a
*condition* and never the nodes behind it: `ReqNodeNotAvail, May be reserved for
other job` is equally true of a job held up by a drained node and one held up by
a maintenance reservation, and those are acted on completely differently. So
`-j` reads the job's nodes and prints each one's state and drain reason, then
every reservation whose node list overlaps them.

**A drained node in that table is yours to fix. A reservation covering the same
nodes means the job is waiting by policy and nothing is broken.**

That is the shape of most Slurm troubleshooting here: the first answer names a
category, and you have to go one level down to get a thing you can act on.

## 5. What Slurm remembers after the job is gone

`squeue` only holds live jobs. Once a job finishes, Slurm keeps it for
`MinJobAge` and then drops it:

```bash
sacct -n -X -o JobID,JobName%22,State,Start,Elapsed --name="bringup-$N" | tail -5
```

You get the last few benchmark jobs that ran on the node, with how long each
took and how it ended. `COMPLETED` is the ordinary case. `TIMEOUT` means Slurm
killed it on its walltime, `CANCELLED` means something or someone stopped it,
and `NODE_FAIL` means the node went away underneath it.

This is the only place the *scheduler's* view of a finished job survives. The
framework's view is the result file, and step 7 is where the two meet.

## 6. What the node decided, in its own words

Slurm can tell you a job ran. It cannot tell you why one did not. That is the
trace:

```bash
tail -20 "results/$N/trigger.log"
```

One timestamped line per agent cycle. Find the newest line starting `EXIT:`
— **that is the reason nothing is happening on this node right now.** On a
healthy node it is almost always the hourly gate:

```
EXIT: newest result is 2117s old, next sweep in 1483s
```

which means: this node has been tested recently, and it will be tested again in
about twenty-five minutes. Nothing is wrong.

Other lines you may see, and what each means:

| Line | Reading |
|---|---|
| `EXIT: waiting on our own queue` | A job of ours is out; step 3 will show it |
| `EXIT: every benchmark passing` | The node is finished |
| `EXIT: node is drain for a reason that is not ours` | Step 2's other half — an operator or Slurm drain |
| `EXIT: <n> job(s) not ours on <node>` | Somebody else is using the node |

Every gate in the sequencer writes one of these before it stops. That is the
whole diagnostic contract: most cycles legitimately have nothing to do, so
"nothing happened" is written down and is distinguishable from "the chain
broke". Every line it can write is in
[reference/trace-lines.md](../reference/trace-lines.md).

## 7. Joining the two halves

Now put the Slurm view and the results view side by side for the same node:

```bash
bash status-check.sh "$N"
bash daily-report.sh "$N"
```

`status-check.sh` gives a verdict per benchmark column. `daily-report.sh` gives
the same row with the **numbers**, and its first column after the node name is
the node's Slurm state — which is the join you have been building up to.

That column is there for one reason: a row of `NOT_RUN` means something
completely different on an `idle` node than on one that has been `drain` all
week. On the idle node it is a framework question — go back to step 6. On the
drained node it is not a mystery at all: nothing could be scheduled onto it.

Read one result file end to end:

```bash
cat "results/$N/allreduce.txt"
```

The last two lines are the fork you will use most:

```
exit status: 0
DONE
```

`exit status:` is the job's own report of whether it *ran*. The word under it is
the verdict, derived just now by the gate. Non-zero exit status under a `FAIL`
means the workload failed and the cause is above it in this file; **zero** under
a `FAIL` means the workload ran clean and the gate rejected the output — so the
reason is in `status-check.sh` and not in this file at all.

## 8. Why a node was drained by a health check

One more path, because it starts in Slurm and ends somewhere else entirely. If
your node's drain reason is a list of check names rather than prose:

```bash
sinfo -n "$N" -o '%E'
bash health-check.sh --diff "$N"
```

`--diff` diffs each check this node fails against the baseline. That is the
fastest route from "drained" to "what is actually different about this
machine".

Note which of those two commands is authoritative: the drain reason is what
Slurm was *told*, and the diff is what is *true*. They part company routinely —
a fault that appeared after the drain was set is not in the reason, and with
`DRAIN_AFTER_FAILED_HEALTH_CHECK=no` there is no reason at all. `--diff` reads
`logs/<node>` either way, so it answers even for a node nothing drained.

Across the fleet, group them:

```bash
bash health-check.sh --summary
```

Nodes are grouped by the *set* of checks they failed, because nodes failing the
same set share one cause and one fix. Sixty nodes failing the same thirty-eight
checks is one incident, not sixty.

## What you now know

The route you just walked is the one to repeat, in this order:

1. `sinfo` — what state is the node in, and **whose** drain is it
2. `squeue` / `check_squeue.sh -j` — is anything out, and what is it waiting on
3. `sacct` — what happened to jobs that have already finished
4. `trigger.log` — what the node itself decided, and why it stopped
5. `status-check.sh` / `daily-report.sh` — what the results say, against the
   Slurm state
6. `health-check.sh --diff` — what is actually different about this machine

The habit worth taking away is step 1 before everything: **the same symptom
means different things depending on whose drain it is**, and that is readable
in one string.

Where to go next:

| Next | Guide |
|------|-------|
| Nothing is running anywhere and you need to know why | [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md) |
| A node failed and you need the device that caused it | [how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md) |
| What every status word and reason string means | [reference/reasons.md](../reference/reasons.md) |
| Which drains clear themselves, and which never do | [explanation/drain-recovery.md](../explanation/drain-recovery.md) |
| Why the sequencer asks the controller as little as it does | [explanation/sequencing.md](../explanation/sequencing.md) |

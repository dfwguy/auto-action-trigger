# Releasing a job the scheduler gave up launching

`slurmd` did not answer at the moment the scheduler tried to start a job, so
Slurm requeued it and *held* it. A held job reads `PENDING` to every query in
this tree while sitting at priority 0: it will never start, however healthy its
nodes later become, and it will not clear when the queue drains.

If the job is one of ours, the sequencer cancels and resubmits it once the
marker goes stale — see
[explanation/sequencing.md#jobs-the-scheduler-has-given-up-on](../explanation/sequencing.md#jobs-the-scheduler-has-given-up-on),
and read a pile of those as a node fault rather than a sequencer one. This page
is for the other case: a job that is **not** a `bringup-<node>` or
`burnin-<node>`, which nothing here will ever touch, and which therefore sits
until somebody decides what to do with it.

## Recognising it

```bash
squeue -t PENDING -o '%.10i %.9T %.11Q %.20u %24j %44r' | grep -i 'requeued held'
bash check_squeue.sh -j 132492      # one job, with the state of every node it asked for
```

Priority 0 and reason `launch failed requeued held` together are the state.
`check_squeue.sh -j` is the useful view, because the reason field names a
condition and never the nodes, and what to do next depends entirely on whether
those nodes are idle, drained, or busy.

`JobHeldUser` and `JobHeldAdmin` are the same priority-0 `PENDING` but a person
chose them. Leave those alone; find out who and why first.

## Whose job is it

On a bring-up cluster the neighbouring work is usually submitted by the same
account this framework runs as, so `User cmods` is not evidence that a job is
ours or yours — it is why the sequencer tells its own work from everyone else's
by name and never by user
([explanation/sequencing.md#the-prefix-is-the-gate](../explanation/sequencing.md#the-prefix-is-the-gate)).
Slurm authorises on uid, so `scontrol release` and `scancel` will both succeed
on a colleague's job without complaint. Find the submitter before using either:

```bash
scontrol show job 132492 | grep -E 'UserId|WorkDir|Command|SubmitLine'
sacct -j 132492 -o JobID,JobName,User,Group,Submit,WorkDir%60
scontrol write batch_script 132492 -        # the script itself, to stdout
```

`WorkDir` and `Command` under a shared account are usually enough to name a
person: a path under somebody's home, or a per-user run directory.

## Release, or cancel and resubmit

Releasing restores the job's priority and leaves everything else — its node
list, its walltime, its submission environment — exactly as it was. That is the
right move only if those are still what you want.

Check the walltime before releasing anything multi-node:

```bash
squeue -j 132492 -O JobID,TimeLimit,NumNodes,ReqNodes
```

**`TimeLimit UNLIMITED` is the case to think about.** Backfill can only start a
small job ahead of a large one when it can prove the small job finishes before
the large one's reservation opens, and a job with no end time makes that
unprovable for the whole rack it holds. Released and running, an unlimited
18-node job stalls the per-node sweep across its own nodes for as long as it
runs — the `ReqNodeNotAvail, May be reserved for other job` symptom in
[diagnose-nothing-running.md](diagnose-nothing-running.md), and the mechanism
from the other side in
[estimate-when-a-job-will-start.md#6-why-our-jobs-start-ahead-of-yours-anyway](estimate-when-a-job-will-start.md#6-why-our-jobs-start-ahead-of-yours-anyway).
`scancel` and resubmit with a real `--time` is usually better than a release.

Then look at what `check_squeue.sh -j` said about the nodes, because release is
a no-op on three of these four:

| Requested nodes | What a release does |
|---|---|
| all `idle` | starts it, next scheduling cycle |
| some `allocated` by our sweep | starts it when those finish; `%L` on the holding job is the wait |
| drained for a reason in `RECOVER_REASONS` — `Prolog error`, `node was stopped`, a rogue process | nothing yet. The recovery resumes those itself, on its own cycle; release after, or release now and let it sit at `ReqNodeNotAvail` |
| drained for anything else — `NVSwitch issues`, an operator's text | nothing, ever. That drain classifies `operator` and no part of this tree clears it. Fix the hardware, or cancel the job |

Which reasons clear themselves is
[manage-drains.md#which-drains-will-clear-themselves](manage-drains.md#which-drains-will-clear-themselves),
and why that pattern list is what it is,
[explanation/drain-recovery.md#what-the-shipped-patterns-actually-mean](../explanation/drain-recovery.md#what-the-shipped-patterns-actually-mean).

## Release it

```bash
scontrol release 132492,132491,132486
```

`scontrol` reports a refusal on stdout and still exits `0`, as `cmsh` and
`scancel` do elsewhere in this tree. Read the output, never the exit status.

Verify — the hold is gone when priority is non-zero and the reason is no longer
`launch failed requeued held`:

```bash
squeue -j 132492,132491,132486 -o '%.10i %.9T %.11Q %24j %20R'
```

```
     JOBID     STATE    PRIORITY NAME                     NODELIST(REASON)
    132491   PENDING           1 microbenchmark_nccl_nccl (Resources)
    132492   PENDING           1 microbenchmark_nccl_nccl (Resources)
    132486   RUNNING           1 microbenchmark_nccl_nccl ink50-dh01-e22-[11-1
```

`(Resources)` is the honest answer — waiting on nodes, in the queue, with a
priority. A released job comes back at the bottom of the queue, so a low number
there is expected and is not the hold.

## When it goes straight back to held

The launch is failing now, rather than the hold being a leftover. That is a node
or prolog problem, not a scheduler one:

```bash
sacct -j 132492 -o JobID,JobName,State,Reason
sinfo -R -n ink50-dh01-f15-[11-18,28-37]
```

`Prolog error` as a drain reason does not say which check objected, and no Slurm
query recovers it — the check wrote its findings to a node-local path under
`RECOVER_PREJOB_LOGS`. What is readable from the head node is the `recover note:`
line the recovery leaves in the node's own trace; see
[explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why](../explanation/reading-the-whole-fleet.md#a-prolog-drain-does-not-say-why).
The most common single cause is a full kernel buffer —
[archive-and-clear-dmesg.md](archive-and-clear-dmesg.md).

Held jobs arriving in a batch, all within an hour or so, are one incident and
not several. Group them by rack before working through them.

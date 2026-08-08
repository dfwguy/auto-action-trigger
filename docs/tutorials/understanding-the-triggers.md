# How the triggers actually fire

Nothing in this framework is a service you start. There is no daemon, no cron,
no queue of work waiting to be processed. There is BCM, firing three scripts on
every node roughly once a minute, forever — and three scripts that each decide,
every time, that there is nothing to do.

That is the part that is hard to believe until you have watched it, so this
tutorial has you watch it. By the end you will have followed one monitoring
cycle from the BCM object that started it to the line it wrote on disk, and you
will know why "nothing is running" is a question with a written answer.

Everything here is **read-only** except one step, which sets a sentinel file and
is clearly marked. Pick a working node and use it throughout:

```bash
N=ink50-dh01-h20-11
cd /home/cmods/bringup
```

## 1. The six objects

BCM holds three **actions** and three **triggers**. An action is "a script, run
this way"; a trigger is "when this is true, run that action". They are separate
objects and either one can be fine while the other is broken, which is the first
thing worth internalising.

Ask BCM what it has:

```bash
cmsh -c "monitoring action; list" | grep -E 'node_health|file_copy|launch_job'
cmsh -c "monitoring trigger; list" | grep -E 'NodeHealth|FileCopy|LaunchJob'
```

Six rows, three of each:

| Trigger | runs Action | which runs |
|---|---|---|
| `NodeHealthTrigger` | `node_health_action` | `actions/node_health.sh` |
| `FileCopyTrigger` | `file_copy_action` | `actions/file_copy.sh` |
| `LaunchJobTrigger` | `launch_job_action` | `actions/launch_job.sh` |

They were registered by `pre-post/create-action-trigger.sh`, which you do not
need to run — it is already done on a working cluster.

## 2. Read one trigger properly

Look at what makes a trigger fire:

```bash
cmsh -c "monitoring trigger; use LaunchJobTrigger; get duringactions"
cmsh -c "monitoring trigger; use LaunchJobTrigger; get disabled"
```

You want `launch_job_action` and `no`.

**Use `get <property>`, never `show`.** `show` prints a padded table that is
easier to read and whose column widths and property names drift between BCM
releases — so a script that parses it matches nothing on the next upgrade and
says so by finding nothing, which is exactly the silent-empty-result failure
this framework is written against. `get` returns one value and cannot drift.

Now the property that shapes everything: `duringactions`. It means **fire on
every monitoring cycle while the condition holds**, and the condition here is
the node's device status being `UP`.

The alternative, `enteractions`, fires once on the *transition* into `UP`. It is
the obvious choice and it is wrong: a node that was already up would never pick
up a newly built container image, or a changed benchmark list, until somebody
rebooted it. `duringactions` is what makes the whole system a loop that
re-evaluates rather than a run that completes.

## 3. Read one action

```bash
cmsh -c "monitoring action; use launch_job_action; get path"
cmsh -c "monitoring action; use launch_job_action; get runon"
cmsh -c "monitoring action; use launch_job_action; get timeout"
```

Three facts, each load-bearing:

- **`path`** is an absolute path, `/home/cmods/bringup/actions/launch_job.sh`.
  BCM runs an action by executing that path, so the file must be executable —
  a `644` action registers cleanly, reports success, and silently runs nothing.
  That is why the registration script preflights the exec bits and refuses
  rather than registering something that will never run.
- **`runon`** is `node`. The script executes on the compute node itself, out of
  the NFS-exported tree, with no working directory to infer anything from —
  which is why the two BCM actions carry their `home=` path literally where
  every other script in the tree resolves its own location.
- **`timeout`** is `2m`, and that is BCM's hard maximum; anything larger is
  rejected outright. Remember that number for step 6.

## 4. Watch a cycle happen

Now the part that makes it real. Watch the trace file grow:

```bash
tail -f "results/$N/trigger.log"
```

Wait a couple of minutes. Lines appear — roughly one per minute, each
timestamped, most of them saying the same thing:

```
2026-08-05 14:22:07 EXIT: newest result is 2117s old, next sweep in 1483s
2026-08-05 14:23:08 EXIT: newest result is 2178s old, next sweep in 1422s
```

Press `Ctrl-C` when you have seen a few.

**That is the whole system running normally.** Every minute, BCM fires the
trigger, the trigger runs the action, the action runs the script on the node,
the script evaluates its gates, finds the hourly one closed, writes down that it
found it closed, and exits `0`.

The countdown in those two lines is the thing to notice: `1483s` then `1422s`.
The node is not idle-and-forgotten, it is idle-and-counting. When that reaches
zero the next benchmark goes out.

## 5. Why it writes that down at all

Ask yourself what those two lines cost: a file grows by about a hundred bytes a
minute per node, forever. Nothing reads them most of the time. Why keep them?

Because of what the alternative looks like. Consider a node that has silently
stopped testing — the trigger got disabled, the tree got replaced, `slurmd`
died, someone renamed a directory. From the outside, that node looks like this:

- `sinfo` says `idle` — a healthy, available node
- `squeue` shows nothing — no work outstanding
- `results/` stops changing — but it also stops changing on a node that has
  passed everything

**Every symptom of a broken chain is also a symptom of a working one with
nothing to do.** There is no observation you can make of the cluster that
distinguishes them.

So each gate writes down why it stopped, and the file itself becomes the
evidence: a line written *this minute* proves BCM fired, the action ran, the
script started, and it reached a decision. The chain is intact by definition,
and whatever is holding the node has already named itself.

That is why the rule in `CLAUDE.md` says a new gate gets a trace line, and an
`exit 0` with no explanation is a bug **even when the behaviour is correct**.

## 6. Why one action detaches its work

Go back to that `2m` timeout, and consider `file_copy.sh`, which rsyncs
container images to node-local disk. A first sync is several gigabytes over NFS.
It cannot finish in two minutes.

If it tried, BCM would kill it partway through, every single cycle, forever —
and the images would never arrive. So `file_copy.sh` starts its `rsync`
detached and returns immediately. The action completes in well under the
timeout; the copy carries on afterwards.

You can see the result of that on the node:

```bash
ssh "$N" 'ls -la /tmp/containers/ 2>/dev/null | head'
```

Those `.sqsh` files got there without any action ever running longer than two
minutes.

## 7. Ask a node what it would do

Rather than waiting for the next cycle, run the sequencer by hand in dry-run
mode. This submits nothing, drains nothing and writes nothing but its own trace,
so it is safe while the trigger is live:

```bash
pdsh -w "$N" '/home/cmods/bringup/actions/launch_job.sh --explain'
```

Read that output slowly — it is the clearest single view of the system you will
get. You are watching every gate be evaluated in order: the pause switches, the
node filter, the drain recovery, the queue, the survey of which benchmarks have
passed, the hourly gate, the fleet-wide cap. Each one either passes or ends the
run with an `EXIT:`.

The last line tells you what the *next* real cycle will do. If it ends in
`WOULD SUBMIT`, the node is due for work and will get it. If it ends in `EXIT:`,
that gate is the answer, and it named itself.

## 8. Now the health side

The other trigger works on the same loop, with one extra idea. Health checks are
expensive and their answers do not change minute to minute, so they do not run
every cycle — they run on a **cadence**, every `HEALTH_INTERVAL_HOURS`, and
sooner when the last run found something. A **sentinel file** jumps that queue.

```bash
ls "logs/$N/"
```

Around thirty-eight files, one per check. Now the one step in this tutorial that
writes something:

```bash
bash health-check.sh --refresh "$N"
ls "logs/$N/refresh"
```

That file is how you ask for a run now. Wait a monitoring cycle, then:

```bash
ls "logs/$N/refresh"
ls -la "logs/$N/" | head -5
```

The sentinel is gone, consumed by the run, and the check outputs have fresh
timestamps. `node_health.sh` fired on the same `duringactions` loop as the
sequencer, saw the sentinel, ran the checks, and removed it.

The cycles in between are not silent either. They write to their own trace, the
same way the sequencer writes to `trigger.log`:

```bash
tail -3 "results/$N/health.log"
cat "logs/$N/.last-check"
bash health-check.sh --explain "$N"
```

Most of those lines are one gate: the last run was recent enough, and here is
when the next one is due. That is the whole cadence — a stamp saying when and
what, and a line saying what was decided about it. See
[explanation/health-cadence.md](../explanation/health-cadence.md).

This is worth understanding because it is the reason a health result can be
*stale rather than wrong*: nothing re-runs those checks until something asks.

## 9. Walk the whole chain at once

You have now looked at each link by hand. There is a script that does all of it
and names the one that is broken:

```bash
bash trigger-debug.sh "$N"
```

It walks seven links in order — action registered, trigger registered and
enabled, trigger has the action bound, script exists on the node, script decided
to submit, `sbatch` accepted the job, Slurm could write the result — plus a
section 0 covering the deployed layout and the pause switches.

Read its output against what you did in steps 1–3. It is the same questions.

**But the order matters, and this is the habit to leave with:** run
`trigger-log.sh` *first*, always.

```bash
bash trigger-log.sh "$N"
```

Fresh traces settle the question on their own — they prove the chain is intact,
so there is nothing for `trigger-debug.sh` to find and whatever is holding the
cluster is a gate that has already explained itself. `trigger-debug.sh` answers
the *other* case, where the traces are stale and nothing is writing them.

Using them in the wrong order means inspecting BCM configuration to discover a
node was simply waiting out its hour.

## What you now know

- Three actions and three triggers, six separate BCM objects, and either half
  of a pair can break independently.
- `duringactions` re-fires every cycle while the node is `UP`, which is what
  makes this a loop rather than a run — and why a node picks up a new image or
  a changed setting without rebooting.
- The action path must be executable, runs on the node, and has two minutes;
  anything longer detaches.
- Every gate writes down why it stopped, because a broken chain and an idle
  cluster are otherwise indistinguishable.
- Health checks run on a sentinel, not on every cycle.
- `trigger-log.sh` before `trigger-debug.sh`, every time.

Where to go next:

| Next | Guide |
|------|-------|
| Nothing is running and you need to fix it now | [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md) |
| Reading the fleet through Slurm | [troubleshooting-with-slurm.md](troubleshooting-with-slurm.md) |
| Every line the trace can write | [reference/trace-lines.md](../reference/trace-lines.md) |
| Why the chain is shaped this way, and driving `cmsh` safely | [explanation/architecture.md](../explanation/architecture.md) |
| What each gate in the sequencer is protecting | [explanation/sequencing.md](../explanation/sequencing.md) |

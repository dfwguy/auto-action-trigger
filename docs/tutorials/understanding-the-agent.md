# How the agent actually fires

Nothing in this framework is a service you start by hand, and nothing in it is a
queue of work waiting to be processed. There is a `systemd --user` timer on every
node firing one script every two minutes, forever — and that script, most of the
time, decides there is nothing to do and says so.

That is the part that is hard to believe until you have watched it, so this
tutorial has you watch it. By the end you will have followed one cycle from the
timer that started it to the line it wrote on disk, seen the head node notice a
node that stopped, and know why "nothing is running" is a question with a written
answer.

Everything here is **read-only** except two steps, both clearly marked. Pick a
working node and use it throughout:

```bash
N=ink50-dh01-h20-11
cd /cluster/bringup
```

## 1. The two timers

There are two units, not six objects. One runs on every node under test, one on
the head node, and both belong to `$JOB_USER` rather than to root:

| Host | Timer | Runs | Every |
|---|---|---|---|
| every node | `bringup-agent.timer` | `agent/node-agent.sh` | `AGENT_INTERVAL_MINUTES` |
| head node | `bringup-supervisor.timer` | `agent/supervisor.sh` | `SUPERVISOR_INTERVAL_MINUTES` |

Ask the node itself:

```bash
clush -w "$N" 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers bringup-agent.timer'
pdsh -R ssh -w "$N" 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user list-timers bringup-agent.timer'
clush -w "$N" 'loginctl show-user cmods -p Linger --value'
pdsh -R ssh -w "$N" 'loginctl show-user cmods -p Linger --value'
```

You want a timer with a next-elapse a minute or two out, and `yes` for lingering.

Lingering is the part people are surprised by. `systemd --user` normally stops a
user's manager when their last session ends — and the node was armed *over ssh*,
so without lingering the timer would die with the session that started it, within
a second, looking exactly like an arm that worked. Lingering makes the manager
start at boot and outlive every session. See
[explanation/the-agent-and-the-watchdog.md#why-lingering](../explanation/the-agent-and-the-watchdog.md#why-lingering).

## 2. Watch a cycle happen

Two files grow on the shared tree. Start with the agent's own:

```bash
tail -f "results/$N/agent.log"
```

Wait a few minutes. One line per cycle, most of them the same:

```
2026-08-09 14:22:07 idle: no job here -- file_copy node_health launch_job
2026-08-09 14:24:09 idle: no job here -- file_copy node_health launch_job
```

That line means the timer fired, the node had no job on it, and all three steps
ran. What each of them then *decided* is in its own trace:

```bash
tail -3 "results/$N/trigger.log"    # the sequencer
tail -3 "$HEALTH_LOG_DIR/$N/health.log" # the health runner
```

```
2026-08-09 14:22:08 EXIT: newest result is 2117s old, next sweep in 1483s
2026-08-09 14:24:10 EXIT: newest result is 2178s old, next sweep in 1422s
```

**That is the whole system running normally.** Every two minutes the timer fires,
the agent writes its heartbeat, finds no job on the node, and runs three scripts;
each evaluates its gates, finds a time gate closed, writes down that it found it
closed, and exits `0`.

The countdown is the thing to notice: `1483s` then `1422s`. The node is not
idle-and-forgotten, it is idle-and-counting. When it reaches zero the next
benchmark goes out.

## 3. The heartbeat, and what it is not

Look at the third file the cycle wrote:

```bash
stat -c '%n %y' "results/$N/.heartbeat"
```

It is empty, and only its timestamp matters. It is touched at the very top of
every cycle, **before every gate**, and it means one thing: the timer fired here.

That is deliberately narrower than it looks. It does not mean the cycle did any
work — a node that is paused, filtered out, or busy with somebody's job writes
the same heartbeat, because all three are nodes in perfect working order. What
the head node is watching for is the node whose *timer* stopped, and that has no
other symptom: nothing gets written, no error appears anywhere, and `sinfo` still
says `idle`.

Prove it to yourself. On a busy node the line reads:

```
2026-08-09 14:26:11 BUSY: job(s) 130938 running here -- no copy, no health check, no submission
```

The cycle did nothing at all — and the heartbeat next to it is still fresh.

## 4. Watch the head node notice

The second timer is the watchdog. Its trace is one file for the whole fleet:

```bash
tail -f results/supervisor.log
```

One line per cycle whether or not it did anything:

```
2026-08-09 14:22:03 checked 216 node(s): 214 fresh, 0 armed, 2 with work on them, 0 not answering, 0 filtered out
```

Now the second step in this tutorial that changes something. Stop one node's
timer, and watch it come back:

```bash
clush -w "$N" 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user stop bringup-agent.timer'
pdsh -R ssh -w "$N" 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user stop bringup-agent.timer'
```

Nothing happens for a while — that is the point. The node keeps reading as `idle`
in `sinfo`, its results are all still there, and no error is written anywhere.
The only thing that changes is that `results/$N/.heartbeat` stops moving.

After `HEARTBEAT_STALE_MINUTES` — ten by default, five cycles — the watchdog
picks it up:

```
2026-08-09 14:33:05 ARM 1 node(s) whose heartbeat is older than 10m: ink50-dh01-h20-11
```

It reaches in once, over `clush`, and runs `agent/install-agent.sh`, which re-enables
the timer. Within a couple of minutes `agent.log` starts again and the heartbeat
moves. Confirm what it heard back:

```bash
cat "results/$N/arm.log"
```

Only `idle` and `drained` nodes are armed. A node with a job on it is left alone
— its agent would stop at the busy gate anyway — which is why the trace counts
"with work on them" separately. See
[explanation/the-agent-and-the-watchdog.md#which-states-are-armed](../explanation/the-agent-and-the-watchdog.md#which-states-are-armed).

## 5. Why any of it is written down

Ask what those lines cost: a couple of hundred bytes a node a cycle, forever, and
nothing reads them most of the time. Why keep them?

Because of what the alternative looks like. Consider a node that has silently
stopped testing — the timer got stopped, the tree got replaced, `slurmd` died,
someone renamed a directory. From the outside:

- `sinfo` says `idle` — a healthy, available node
- `squeue` shows nothing — no work outstanding
- `results/` stops changing — but it also stops changing on a node that has
  passed everything

**Every symptom of a broken chain is also a symptom of a working one with nothing
to do.** There is no observation you can make of the cluster that separates them.

So the heartbeat proves the timer fired, and each gate writes down why it
stopped. Between them, a line written *this cycle* means the chain is intact by
definition, and whatever is holding the node has already named itself.

That is why the rule in `CLAUDE.md` says a new gate gets a trace line, and an
`exit 0` with no explanation is a bug **even when the behaviour is correct**.

## 6. Why one step detaches its work

`file_copy.sh` rsyncs container images to node-local disk, and a first sync is
several gigabytes over NFS. It cannot finish inside a cycle.

If it tried, it would hold the agent's lock across the next cycle and the one
after that, and nothing else on the node would run. So it starts its `rsync`
detached and returns immediately; the copy carries on afterwards, and a `flock`
stops the next cycle stacking a second one on top.

```bash
clush -w "$N" 'ls -la ${NODE_CONTAINER_DIR:-/opt/containers}/ 2>/dev/null | head'
pdsh -R ssh -w "$N" 'ls -la ${NODE_CONTAINER_DIR:-/opt/containers}/ 2>/dev/null | head'
```

Those `.sqsh` files got there without any cycle ever running long.

## 7. Ask a node what it would do

Rather than waiting, run a cycle by hand in dry-run mode. It submits nothing,
drains nothing and writes nothing but its own trace, so it is safe while the
timer is live:

```bash
clush -w "$N" '/cluster/bringup/agent/node-agent.sh --explain'
pdsh -R ssh -w "$N" '/cluster/bringup/agent/node-agent.sh --explain'
```

Read that output slowly — it is the clearest single view of the system you will
get. You are watching every gate be evaluated in order: the exclusions, the busy
gate, then inside the sequencer the pause switches, the node filter, the drain
recovery, the queue, the survey of which benchmarks have passed, the hourly gate,
the per-node submission guard. Each one either passes or ends the run with an `EXIT:`.

If it ends in `WOULD SUBMIT`, the node is due for work and will get it. If it
ends in `EXIT:`, that gate is the answer, and it named itself.

## 8. Now the health side

The health checks work on the same loop with one extra idea. They are expensive
and their answers do not change minute to minute, so they do not run every cycle
— they run on a **cadence**, every `HEALTH_INTERVAL_HOURS`, and sooner when the
last run found something. A **sentinel file** jumps that queue.

```bash
ls "logs/$N/"
```

Around thirty-eight files, one per check. Now the second step that writes
something:

```bash
bash report_health.sh --refresh "$N"
ls "logs/$N/refresh"
```

That file is how you ask for a run now. Wait an agent cycle, then:

```bash
ls "logs/$N/refresh"
ls -la "logs/$N/" | head -5
```

The sentinel is gone, consumed by the run, and the check outputs have fresh
timestamps.

Seven of those checks read `dmesg`, one reads `dmidecode`, three walk PCIe
config space — all of which need root, on a cycle that is not root. They go
through `sudo -n`, and a missing rule stops the whole run rather than producing
output that would be diffed against a baseline captured with privilege. See
[explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run](../explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run).

The cycles in between are not silent either:

```bash
tail -3 "$HEALTH_LOG_DIR/$N/health.log"
cat "logs/$N/.last-check"
bash report_health.sh --explain "$N"
```

Most of those lines are one gate: the last run was recent enough, and here is
when the next is due. That is the whole cadence — a stamp saying when and what,
and a line saying what was decided about it. See
[explanation/health-cadence.md](../explanation/health-cadence.md).

This is why a health result can be *stale rather than wrong*: nothing re-runs
those checks until something asks.

## 9. Walk the whole chain at once

You have now looked at each link by hand. There is a script that does all of it
and names the one that is broken:

```bash
bash check_trigger-debug.sh "$N"
```

It walks seven links in order — the watchdog is cycling, the node's heartbeat is
fresh, linger and timer on the node, sudo rules on the node, the script decided
to submit, `sbatch` accepted the job, Slurm could write the result — plus a
section 0 covering the deployed layout and the pause switches. Links 1 and 2 are
answered from NFS; `--ask-nodes` adds 3 and 4, which cost a shell per node.

**But the order matters, and this is the habit to leave with:** run
`check_trigger-log.sh` *first*, always.

```bash
bash check_trigger-log.sh "$N"
```

Fresh traces settle the question on their own — they prove the chain is intact,
so there is nothing for `check_trigger-debug.sh` to find and whatever is holding the
cluster is a gate that has already explained itself. `check_trigger-debug.sh` answers
the *other* case, where the heartbeats have stopped and nothing is writing
anything.

Using them in the wrong order means going node by node through systemd to
discover a node was simply waiting out its hour.

## What you now know

- One timer per node and one on the head node, both `systemd --user` under
  `$JOB_USER`, both needing lingering to survive the ssh that started them.
- The heartbeat says the timer fired; every other file says what a cycle
  decided. One file cannot answer both questions.
- The watchdog arms `idle` and `drained` nodes whose heartbeat has gone stale,
  over one `clush`, and gives up after `ARM_MAX_ATTEMPTS` rather than sshing for
  ever.
- A node with any job on it does nothing but say so.
- Every gate writes down why it stopped, because a broken chain and an idle
  cluster are otherwise indistinguishable.
- Health checks run on a cadence and a sentinel, not on every cycle, and they
  refuse to run at all rather than judge a node without the privilege they need.
- `check_trigger-log.sh` before `check_trigger-debug.sh`, every time.

Where to go next:

| Next | Guide |
|------|-------|
| Nothing is running and you need to fix it now | [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md) |
| A node that will not stay armed | [how-to/arm-a-node.md](../how-to/arm-a-node.md) |
| Reading the fleet through Slurm | [troubleshooting-with-slurm.md](troubleshooting-with-slurm.md) |
| Every line the trace can write | [reference/trace-lines.md](../reference/trace-lines.md) |
| Why the chain is shaped this way | [explanation/the-agent-and-the-watchdog.md](../explanation/the-agent-and-the-watchdog.md) |
| What each gate in the sequencer is protecting | [explanation/sequencing.md](../explanation/sequencing.md) |

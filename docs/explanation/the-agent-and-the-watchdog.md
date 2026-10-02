# The agent and the watchdog

Every cycle on every node used to start in BCM: three monitoring triggers fired
three scripts as root, about once a minute, while the node's device status was
`UP`. That worked, and it made the cluster manager load-bearing for a framework
that has nothing to do with cluster management. A site without BCM could not run
this at all, an action could not take longer than BCM's hard 2-minute ceiling,
and the first question when nothing was running was answered in `cmsh`.

The head node is still BCM-managed. It is simply not in this path any more.

```
head node                                  every node under test
────────────────────────────────────────   ──────────────────────────────────
systemd --user (lingering, JOB_USER)       systemd --user (lingering, JOB_USER)
  bringup-supervisor.timer  every 2m         bringup-agent.timer  every 2m
        │                                          │
        ▼                                          ▼
  agent/supervisor.sh                        agent/node-agent.sh
        │  sinfo + squeue: the fleet's one         │  touch .heartbeat
        │    look at Slurm, written per node        │  any job here? -> say so, stop
        │  stat:  whose heartbeat is stale          │  reads its own .slurm-view
        │                                           │
        └──── clush -w ──────────────►        ├── actions/file_copy.sh
        └──── clush -w ────────────────────►        ├── actions/file_copy.sh
              agent/install-agent.sh                ├── actions/node_health.sh
                                                    └── actions/launch_job.sh
                        ▲                                  │
                        └────── results/ on NFS ◄──────────┘
```

Two facts move between the halves, and both are files on the exported tree:
`results/<node>/.heartbeat`, which the node writes and the head node reads, and
everything under `results/<node>/` that the reports already read. Nothing polls
a node to ask whether it is alive.

## What the heartbeat means

`results/<node>/.heartbeat` is touched at the top of every cycle, before any
gate, and it means exactly one thing: **the timer fired here**. It does not mean
the cycle did any work, and it deliberately cannot be read that way.

The distinction matters because most cycles legitimately do nothing. A node that
is paused, filtered out by `NODE_FILTER`, waiting out a health-check interval or
busy with somebody's job is a node in perfect working order, and arming it again
would achieve nothing. `RUN_JOBS` and the other `RUN_*` switches in
[reference/settings.md#run-switches](../reference/settings.md#run-switches)
are read well after the heartbeat touch, so none of them can produce a stale
one — a paused node keeps writing `.heartbeat` on schedule. What the watchdog is
looking for is the node whose *timer* has stopped — because the user manager was
killed, because lingering was never enabled, because the machine was reimaged,
because somebody ran `systemctl --user stop`, or because `admin_pause-agents.sh` did
that on purpose fleet-wide for a tarball drop. None of those write anything to
any log; the only evidence is an absence, so the absence has to be of something
written unconditionally.

That is also why the heartbeat is written **above the flock**. A cycle wedged in
a long rsync still has a working timer, and re-arming would not unwedge it. That
case shows up as a stalled `agent.log` next to a fresh heartbeat, which is a
different fault with a different fix, and the two must not be collapsed.

Everything else in `results/<node>/` — `trigger.log`, `health.log`, the result
files themselves — says what a cycle *decided*. The heartbeat says a cycle
happened. Silence is the enemy in both directions, and one file cannot answer
both questions.

## Whose clock decides

Heartbeat ages are compared against **another file on the same share**, not
against the head node's clock. `supervisor.sh` touches
`results/.supervisor-heartbeat` at the top of its cycle and uses that file's
mtime as "now".

Both times then come from the NFS server, because a `touch` resolves its
timestamp server-side. A head node whose clock has drifted forward by an hour
therefore cannot conclude that the entire fleet has stopped and re-arm two
hundred healthy nodes, and one that has drifted backwards cannot conclude that
nothing has stopped. NTP normally makes this a non-issue and the trick costs one
`touch`, which is worth paying for a failure mode whose symptom is a fleet-wide
storm of ssh.

The same file is the watchdog's own liveness marker, and it is the only one:
nothing watches the watchdog. Its absence or staleness is the first thing
`check_trigger-log.sh` and `check_trigger-debug.sh` report, above every per-node question,
because no answer below it can be trusted while nothing is arming anything.

## Where the watchdog logs

Four places, and only the first is the one to read:

| What | Where |
|---|---|
| One line per cycle, including the quiet ones | `$RESULTS_DIR/supervisor.log` |
| Its own liveness | `$RESULTS_DIR/.supervisor-heartbeat` — mtime only, and the clock every other age is measured against |
| What it heard back from one node, per attempt | `$RESULTS_DIR/<node>/arm.log` |
| Anything it could not write, plus login-shell noise from the unit | the systemd journal |

The unit passes `--quiet`, so a healthy cycle writes to the file and says nothing
to stdout. `journalctl --user -u bringup-supervisor.service` is therefore empty
on a working head node, which is the point: it holds the failures the file could
not.

The one that matters is a `results/` the account cannot write — a tree left
root-owned by the years these cycles ran as root is exactly that. Without a
guard the watchdog would run, write nothing anywhere, and leave
`systemctl --user status` reporting a clean oneshot while the fleet quietly
stopped being armed. So writability is tested once per run and a failure turns
the run verbose, which puts every line in the journal instead, with the `chown`
in the first of them. A run that can neither write nor speak is the one state
this whole design exists to make impossible, and the watchdog is the worst place
to have it: nothing watches the watchdog.

## Which states are armed

From the same `sinfo` the node views are cut from — see
[the-fleet-snapshot.md](the-fleet-snapshot.md) — once per cycle, and only two
states are candidates:

| State | Armed | Why |
|---|---|---|
| `idle` | yes | ready for work and not doing any |
| `drained` | yes | its health checks are what may clear the drain, and `launch_job.sh` recovers drains Slurm set itself |
| `allocated`, `mixed`, `draining` | no | there is work on the node; the agent there would stop at the busy gate anyway |
| anything with a trailing `*` | no | slurmd is not answering, which arming does not fix |
| `down`, `maint`, `reserved`, `planned` | no | somebody's arrangement, or a machine that is not coming back on its own |

Drained is the one worth arguing about, and it is included deliberately: a
drained node is exactly the node somebody wants re-checked, and excluding it
would mean a node that drains once is never health-checked again — the drain
becomes permanent by omission.

The cost of the `allocated` exclusion is that an agent which dies *while a job
runs* is not re-armed until the job ends. That is bounded by `MAX_JOB_HOURS`
and is the cheaper half of the trade: the alternative is arming nodes that are
busy, every cycle, for the whole length of every job.

An empty `sinfo` is not an answer. A saturated `slurmctld` exits 0 with no
output, and a fleet-wide re-arm on that basis is precisely the kind of damage
[sequencing.md#when-the-controller-does-not-answer](sequencing.md#when-the-controller-does-not-answer)
describes. The cycle traces it and stops — and, just as importantly, rewrites no
node views. Every node keeps the one it has until it ages out, rather than two
thousand of them being blanked at once because the controller was busy.

## What else the watchdog carries

Arming is the oldest of its jobs and no longer the largest. It is also the only
host in the deployment that asks slurmctld anything, and four decisions live
here because they need a view of the whole fleet or because making them per node
cost a query per node per cycle:

- the node views themselves, one small file per node
- `MAX_JOB_HOURS`, which the node's own cycle cannot reach past the busy gate
- pending jobs under `RUN_JOBS=no`, and jobs the scheduler gave up launching
- [giving a node back](sequencing.md#getting-out-of-the-way) to somebody queued for it

All of it is in [the-fleet-snapshot.md](the-fleet-snapshot.md). The consequence
for operating the fleet is that a watchdog which has stopped no longer merely
stops re-arming dead nodes — it stops every healthy node deciding anything, one
`SLURM_SNAPSHOT_MAX_AGE_MINUTES` later. Each of them says so, every cycle, and
names the file it is missing.

## One unit for both roles

`$HOME` is NFS-shared at most sites, and that is not an incidental detail — it
is the constraint the unit layout has to survive. `~/.config/systemd/user/` is
therefore the *same directory* on the head node and on every tray, and so is the
`timers.target.wants/` symlink that `systemctl --user enable` writes. A fleet of
2,000 hosts shares one set of unit files and one enable state.

Two units, one per role, cannot survive that, and the ways it fails are worse
than they look:

- Installing the watchdog on the head node **enables it for every tray**, since
  the enable symlink is shared. Two thousand watchdogs, all reading `sinfo` and
  all arming each other.
- Installing the node agent on a tray, and the watchdog on the head node, has
  each install *remove* the other's units — they are the same files.
- Every host in one `clush` writes that directory at the same moment. A single
  temp filename had them taking each other's file: `mv` on a name another host
  had already moved, and a zero-length unit left behind. **systemd reports an
  empty unit file as masked**, which is a confusing way to be told that two
  hosts raced.

So there is one unit, `bringup-agent`, installed identically everywhere, and
`agent/cycle.sh` asks `agent_role` on every run and hands over to
`supervisor.sh` or `node-agent.sh`. The role becomes a run-time property of the
host rather than something baked into a file the whole fleet reads — which is
also more honest, because a host's role *can* change and nothing has to be
reinstalled when it does.

Two consequences worth knowing:

- **One timer, one interval.** `AGENT_INTERVAL_MINUTES` fires every host.
  `SUPERVISOR_INTERVAL_MINUTES` is enforced by `supervisor.sh` itself, which
  returns immediately when its own heartbeat is younger than that — so the
  setting still means what it says, and the head node's extra cycles cost a
  `stat`.
- **Writes still have to be safe.** The temp file carries the hostname and the
  pid, and a unit that is already byte-identical is not rewritten at all — so in
  steady state, arming 2,000 trays writes that directory zero times.

## Why the timer is a calendar

`OnCalendar=*:0/2`, not `OnUnitActiveSec=2min`, and the difference is not a
matter of taste. It cost a fleet a day.

A monotonic timer is measured from the last activation of the unit it triggers.
`Type=oneshot` finishes, the service goes inactive, and once systemd has no
reference left to that activation there is nothing to measure two minutes from —
so it computes a next elapse of `infinity`. The timer stays `active`, reports
`Result=success`, and never fires again. On 2,016 hosts it fired exactly once
each, at the moment the watchdog armed them:

```
ActiveState=active   Result=success   LastTriggerUSec=Sun 2026-08-09 18:35:09
NextElapseUSecMonotonic=infinity
```

Every symptom pointed somewhere else. `systemctl --user status` was clean, the
unit file was correct, lingering was on, the manager had been up for half an
hour, and a cycle run by hand worked perfectly. The fleet even *looked* healthy
from the watchdog — 1,672 fresh heartbeats — because the watchdog re-arms a node
whose heartbeat has gone stale, and re-arming restarts the timer, which fires
once. The repair loop was hiding the fault it was repairing.

A calendar schedule has no such reference: the next elapse is computed from the
wall clock and always exists. `RandomizedDelaySec=30` smears the fleet across
half a minute so two thousand nodes do not hit NFS on the same second, and
`Persistent=false` means a node that was powered off does not run a catch-up
burst when it comes back.

Two consequences:

- **The interval has to divide 60.** `*:0/N` repeats within the hour, so an `N`
  that does not divide it makes the last step of each hour short. `install-agent.sh`
  rejects one that does not and uses 2.
- **`enable --now` no longer produces an immediate cycle.** It starts the timer,
  and a calendar timer waits for its first tick — so the install starts one
  cycle itself, or a freshly armed node would look silent for a whole interval
  and be armed again.

The check that would have caught this in an hour rather than a day is now part
of the install: **active is not the same as scheduled**, and a timer with no next
elapse is a failure with the two commands to run printed under it.

That check has to be patient, though. `systemctl restart` returns before the
timer has computed its next elapse, so asking immediately gets an empty answer
from a node that is healthy a second later — which produced a screen of `FAILED`
lines for a fleet that was fine. It now retries for a couple of seconds, and an
answer it still cannot read is reported as unreadable rather than as broken.

### Why the next elapse is not the question

Patience was not enough, and could not have been. The signature the check failed
on was "no realtime elapse *and* a monotonic elapse of `infinity`" — which is
what the fault above looks like, and also what a **healthy** calendar timer looks
like for the moment after it is restarted. A calendar timer has no monotonic
schedule at all, so `NextElapseUSecMonotonic` is `infinity` by construction,
for ever, on every node that is working perfectly; and `NextElapseUSecRealtime`
is `0` until the manager gets round to computing it. Two values, one of them
constant and the other a race. On a fleet-wide `admin_pause-agents.sh --resume` this
put a `FAILED` line and a non-zero exit against hundreds of nodes at once, every
time, and every one of them was cycling a minute later — so the output taught its
readers to ignore it, which is worse than not printing it.

The distinguishing fact is not *when* the timer next fires but *which schedule
it is carrying*, and systemd answers that directly:

```bash
systemctl --user show bringup-agent.timer -p TimersCalendar -p TimersMonotonic
```

A loaded calendar unit has a `TimersCalendar=` and no monotonic one; the fault is
the exact reverse, a `TimersMonotonic=` with no calendar. Neither answer changes
while the manager settles, so the check needs no timing luck to be right. It now
reads: an elapse it can use passes, a monotonic-only timer fails, a calendar
timer with no elapse yet is active-and-not-yet-computed, and anything else is
systemd not answering. Four outcomes, one of them the fault.

The rule this is an instance of is that a signature shared by the failure and the
healthy case is not a check. It is a coin toss that costs a fleet's attention.
`tests/arm-timer-test.sh` holds all four.

## What a cycle costs the share

Everything the agent reads lives on one NFS export, and a fleet multiplies every
read in a cycle by its node count. At 2,016 nodes on a two-minute interval, one
file read per cycle is 17 reads a second, sustained, for ever.

That arithmetic caught this tree once. `node_health.sh` preflights the sudo
rules by reading every check file to find the commands they need — 38 files —
and that ran *above* the cadence gate, so it happened on every cycle rather than
on every run. 2,016 × 38 every two minutes is around 640 reads a second for an
answer worth having every four hours. It now sits below the gate.

Two things follow for anyone adding to a cycle:

- **Put work below the gate that decides whether the work happens.** A gate that
  is cheap to evaluate is worth evaluating first even when the code reads worse.
- **`RandomizedDelaySec` is half the interval**, substituted at install like the
  interval itself, so a fleet of any size arrives smeared rather than on the
  tick. It does not reduce the load, only its shape — but a share that copes
  with a steady rate can fail on the same total delivered in one second.

`AGENT_INTERVAL_MINUTES` is the lever when a fleet is large enough that the
steady rate is the problem. Nothing in the cadence gates is a cycle count —
every one of them is a time gate — so raising it costs responsiveness and
nothing else. The other lever is `RUN_CONTAINER_COPY`, because the one thing
in a cycle that moves gigabytes rather than kilobytes is the image rsync.

## Only one watchdog

Every host runs the same unit and decides its own role, so nothing about the
install stops two hosts reading as head — a second management server, a host
that lost its `slurmd`, a compute node named in `EXCLUDE_NODES`. Two watchdogs
arm the same fleet, race each other's `arm.log`, and double every ssh.

A claim on the shared tree settles it. `results/.supervisor-owner` holds the
hostname of whoever is arming, refreshed on every cycle; a host that finds a
claim younger than the lease stands by and says which host is holding it. The
lease is three watchdog intervals with a five-minute floor, so one slow or
skipped run does not hand the fleet over — but a watchdog whose host dies is
taken over, and the takeover is written down.

The claim is read and written **above** the heartbeat, because a host standing by
must not touch the marker that says a watchdog is alive. That would leave the
fleet looking supervised by a host that is doing nothing.

`SUPERVISOR_HOST` names one host and settles it deterministically, which is the
right answer for a site that genuinely has two candidates. Empty — the shipped
value — means whoever claims it first and keeps the claim fresh.

Two hosts can still both act for one cycle if they claim in the same instant.
That is bounded and cheap: arming is idempotent, and the loser stands by from
the next cycle. A lock would be the alternative, and a lock on NFS that can be
held by a host that reboots is a worse failure than a claim that is occasionally
raced.

## Why lingering

`systemd --user` normally starts a user's manager at their first login and stops
it at their last logout. The watchdog arms a node over ssh, so without
`loginctl enable-linger` the timer it just started would die with the ssh
session that started it — reliably, within a second, and looking exactly like an
arm that worked.

Lingering makes the user manager start at boot and outlive every session, which
is what a timer needs. It is enabled by `install-agent.sh`, which tries
directly first and then through `sudo`: whether an unprivileged user may linger
themselves is a polkit policy that varies between distributions, and over ssh —
with no seat — the permissive answer is not the common one.

Enabling it is not the same moment as it taking effect: the flag is read at
session start, so a session already open when `loginctl enable-linger` runs —
including the one running `install-agent.sh` for the first time — gets no bus
from it. `install-agent.sh` checks for that bus rather than trusting the flag,
and refuses to go further if it is missing, since every `systemctl --user`
call after it would fail for the same one reason. See
[how-to/enable-lingering-before-installing.md](../how-to/enable-lingering-before-installing.md).

The unit itself is **copied** into `~/.config/systemd/user/` rather than
symlinked into the exported tree, so a tree being replaced mid-drop cannot leave
a host with a half-written unit. That directory is usually on NFS as well, which
is [its own constraint](#one-unit-for-both-roles).

A system-level unit under `/etc/systemd/system` would need no linger, and would
need root on every node to install and to change. That is the thing this whole
change is removing.

## The busy gate belongs to the node

A node with any job on it — ours or a neighbour's — writes one line and ends its
cycle. Why that is the right cut, and the two behaviours that had to move to the
watchdog because of it, is
[sequencing.md#the-busy-gate](sequencing.md#the-busy-gate).

## Choosing the three numbers

`AGENT_INTERVAL_MINUTES` (2), `SUPERVISOR_INTERVAL_MINUTES` (2) and
`HEARTBEAT_STALE_MINUTES` (10) are one decision in three parts, and the only
relationship that has to hold is that the last is several times the first.

Two minutes is the node cycle because it is short enough that a node freed by a
finishing job picks up its next benchmark quickly, and long enough that the work
in a cycle — a `scontrol listjobs`, a few `stat`s, and on most cycles nothing
else — is not a measurable load. It is roughly what BCM was doing, which is the
cadence the retry and cadence gates in `launch_job.sh` and `node_health.sh` were
written against; changing it does not change any of their behaviour, because
every one of them is a time gate rather than a cycle count.

Ten minutes is the staleness bound because it is five cycles. One missed cycle
is a slow NFS write or a `RandomizedDelaySec` landing badly; five in a row is
not. Set it lower and a node that is merely slow gets an ssh it does not need;
set it much higher and a genuinely stopped node sits idle for that long. The
worst case between a node's timer dying and its being armed again is
`HEARTBEAT_STALE_MINUTES` plus one supervisor interval.

`RandomizedDelaySec=30` in the node timer exists so that two hundred nodes armed
in the same fan-out do not then hit the same NFS server in the same second for
the rest of the day.

## Arming is bounded

`install-agent.sh` may be run any number of times on a node that is already
armed: it re-enables lingering that is already enabled, rewrites the units only
when they differ, and `systemctl --user enable --now` on a running timer is a
no-op. That is what makes it safe for the watchdog to run it without first
asking whether it is needed — and the watchdog cannot ask cheaply, because the
question is on the other side of an ssh.

What it is not is free, so it is rate-limited three ways. **`ARM_BATCH` caps how
many nodes one cycle reaches at all** — every arm is an ssh, and ssh is CPU on
the host doing the arming, so an uncapped pass across a fleet that has stopped
cycling is two thousand handshakes from one machine, repeated every interval.
That is not hypothetical: it is what a fleet-wide timer fault produces, because
a fleet that stops cycling makes *every* node stale in the same instant. The
overflow is deferred to the next cycle and named in the trace, never dropped.

A watchdog cycle also takes a node-local `flock`. Arming a large fleet can take
longer than the interval, and systemd queues a start it cannot run concurrently
— so without it a slow cycle is followed immediately by the next, and the
fan-out never stops.

Then, per node: one is not armed again within `ARM_RETRY_MINUTES`, and one armed
`ARM_MAX_ATTEMPTS` times inside `ARM_WINDOW_HOURS` and still silent is left alone
and named in the summary line.
The shape is deliberately the same as `RECOVER_MAX_ATTEMPTS` in
[drain-recovery.md](drain-recovery.md), and for the same reason: a repair that
is not working is a fact to report, not a thing to keep doing. Every attempt and
what came back from it is appended to `results/<node>/arm.log`.

The arm goes out as a single `clush -w` over the whole list rather than a
loop of sshes, per
[architecture.md#reaching-nodes-is-clush-or-pdsh](architecture.md#reaching-nodes-is-clush-or-pdsh).
Per-node output is attributed back and traced, which is how `ARM FAILED` lines
get a node name on them.

## What this does not solve

The watchdog is a single host, and if it stops, nothing arms anything. What
happens then is that the fleet keeps working — every node already armed keeps
cycling, benchmarking and reporting, because the agent depends on nothing but
its own timer and the shared tree. What stops is recovery: a node that goes
quiet stays quiet. That degradation is deliberate and it is why the watchdog's
own heartbeat is reported first everywhere.

Making the watchdog redundant would mean two hosts deciding to ssh into the same
node, which is harmless (arming is idempotent) but needs a shared attempt record
to keep the rate limit honest. Nothing needs it yet.

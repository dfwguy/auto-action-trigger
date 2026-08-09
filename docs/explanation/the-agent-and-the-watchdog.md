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
        │  sinfo: who is idle or drained            │  touch .heartbeat
        │  stat:  whose heartbeat is stale          │  any job here? -> say so, stop
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
would achieve nothing. What the watchdog is looking for is the node whose *timer*
has stopped — because the user manager was killed, because lingering was never
enabled, because the machine was reimaged, because somebody ran
`systemctl --user stop`. None of those write anything to any log; the only
evidence is an absence, so the absence has to be of something written
unconditionally.

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
`trigger-log.sh` and `trigger-debug.sh` report, above every per-node question,
because no answer below it can be trusted while nothing is arming anything.

## Which states are armed

`sinfo -N -h -o '%N %T'`, once per cycle, and only two states are candidates:

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
describes. The cycle traces it and stops.

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

The units themselves are **copied** into `~/.config/systemd/user/` rather than
symlinked into the exported tree. Home directories are on NFS here too, so this
does not buy independence from NFS entirely; what it does buy is that systemd
reads a small local-ish file at daemon-reload rather than following a symlink
into a large shared tree at every start, and that a tree being replaced mid-drop
cannot leave a node with a half-written unit.

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

## Arming is idempotent, and bounded

`install-agent.sh` may be run any number of times on a node that is already
armed: it re-enables lingering that is already enabled, rewrites the units only
when they differ, and `systemctl --user enable --now` on a running timer is a
no-op. That is what makes it safe for the watchdog to run it without first
asking whether it is needed — and the watchdog cannot ask cheaply, because the
question is on the other side of an ssh.

What it is not is free, so it is rate-limited twice. A node is not armed again
within `ARM_RETRY_MINUTES`, and a node armed `ARM_MAX_ATTEMPTS` times inside
`ARM_WINDOW_HOURS` and still silent is left alone and named in the summary line.
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

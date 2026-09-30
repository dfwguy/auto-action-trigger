# The fleet snapshot

Two thousand agents used to ask slurmctld the same questions about themselves,
every two minutes, for ever. Now the head node asks twice for the whole fleet and
writes the answers where every node can read them.

This page is why that shape, what a node is allowed to read, and — the part that
matters most — what a node must do when the answer is not there.

## The arithmetic that forced it

Every query in a cycle is multiplied by the fleet. On two thousand nodes at
`AGENT_INTERVAL_MINUTES=2` that is roughly seventeen nodes a second, sustained,
and each of them was making three round trips to the controller:

| Where | Call | When |
|---|---|---|
| `actions/node_health.sh` | `sinfo -N -n $HOSTNAME` | every cycle |
| `slurm-recovery.sh` | `sinfo -N -n $node` | every idle cycle |
| `actions/launch_job.sh` | `squeue -h -o '%i %j'` — **the whole queue** | every cycle reaching a submission |
| `actions/launch_job.sh` | `scontrol show node $HOSTNAME` | on the drain and resume paths |
| `slurm-recovery.sh` | `squeue -w $node` | while the node is drained |
| `get-out-of-the-way.sh` | `squeue -t PENDING` — **the whole pending queue** | polled while our job runs |

Fifty-odd RPCs a second in steady state, two of them full queue listings, to
answer questions whose answers are identical across the fleet. A saturated
controller then returns empty to *everything*, which is the failure mode
[sequencing.md#when-the-controller-does-not-answer](sequencing.md#when-the-controller-does-not-answer)
exists to describe — so the load was also manufacturing the ambiguity every
caller had to be careful about.

The controller-side cost is now two queries per `SUPERVISOR_INTERVAL_MINUTES`,
for any fleet size.

## The two queries

`slurm-snapshot.sh` is the only file in the tree that runs `squeue` or `sinfo`,
and `agent/supervisor.sh` is the only thing that sources its writer half.

```
sinfo  -N -h -o '%N|%T|%u|%H|%E'
sinfo  -N -h -o '%N|%G|%c'
squeue -h -a -o '%i|%j|%u|%T|%Q|%V|%e|%N|%n|%Y|%D|%r'
```

Three calls, two commands. The split in `sinfo` is not fussiness: `%E` is a
drain reason, which is free text with spaces in it, so it has to be the last
field — and the GRES and CPU counts a count drain is judged against cannot go
after it. The same rule puts `%r` last in the `squeue` format.

`%D` is there for one reader. It is the number of nodes a pending job needs, and
without it a node list says only which nodes a job named, never whether enough
of them are in a state Slurm can schedule — which is the difference between a
job that starts the moment a benchmark stops and one that was never going to
start at all. The first `sinfo` call answers the other half, and both are read
together in
[sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter](sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter).

`-o` and not `-O`. `--Format` pads every field to a default width and truncates
what does not fit, which for `NodeList` on a large allocation means a silently
shortened node list. The `%`-style format does neither.

## Why it is sharded

The obvious design is one `queue.psv` on the share that every node greps. It is
also wrong, and for exactly the reason the queries were wrong: a fleet-wide file
grows with the fleet, and every node reads all of it every cycle. Two thousand
nodes reading a 200 kB queue dump every two minutes is 3 GB/s of NFS traffic to
answer a question about one line each.

So the watchdog does the join and writes **one small file per node**, beside the
heartbeat that node already writes:

```
$RESULTS_DIR/<node>/.slurm-view
```

A few hundred bytes, and a node reads only its own. The fleet-wide copies still
land in `results/.slurm/nodes.psv` and `results/.slurm/queue.psv` for the head
node's own tools and for anyone debugging a view, and nothing on a compute node
reads them.

## What is on disk

Tab separated, key first, and the free-text fields run to the end of their line:

| Key | Holds |
|---|---|
| `stamp` | the epoch the watchdog wrote this view |
| `state` | the node's Slurm state, as `sinfo %T` gives it |
| `setter` | who set the drain, or `none` |
| `when` | when the drain was set |
| `gres` | configured GRES, for a count drain |
| `cputot` | configured CPUs, for a count drain |
| `fleet` | how many jobs of ours are queued or running fleet-wide |
| `job` | one per job Slurm has assigned to this node: id, state, user, end epoch, name |
| `ours` | one per job carrying this node's own two job names, anywhere in the queue: id, state, name, reason |
| `reason` | the drain reason, free text |
| `end` | the sentinel — see below |

`job` and `ours` are different questions and both are needed. A PENDING job has
no node list at all, so it appears under `ours` and never under `job`; that is
the case the guard before a submission exists for. A neighbour's job running here
appears under `job` and never under `ours`.

An end epoch of `none` means the job has no time limit. Nothing may read that as
"expired" — see
[drain-recovery.md#a-step-that-outlives-its-own-kill](drain-recovery.md#a-step-that-outlives-its-own-kill).

### A torn read says nothing

The view is truncated in place and not renamed. A rename per node per cycle is
two thousand extra forks on one host every two minutes, to buy atomicity that is
cheaper to detect than to provide.

So the writer seals each file with `end`, and `snapshot_load` refuses any view
that does not carry one. A reader arriving mid-write sees a prefix, finds no
sentinel, and treats it as no answer — which is a branch every caller already
has. The next cycle finds a whole file.

### The server must not hand out delegations

Truncating in place has a second consequence, and it cost a fleet ten hours
before anyone found it.

Every node polls its own view read-only, every cycle, and never writes it. That
is precisely the access pattern NFSv4 hands out a read *delegation* for: the
server tells the client it may cache the file authoritatively, because nobody
else is touching it. The client is wrong about that once a cycle. When the
watchdog reopens the file to truncate it, the server must recall the delegation
before the write may proceed — and a client that does not answer costs the full
recall timeout, roughly thirty seconds, per file.

That is invisible in every place you would look. The write is a handful of
`printf` builtins into a file of about 150 bytes; the block device sits idle at
single-digit utilisation with sub-millisecond latency; the process burns no CPU
because it is parked in the kernel. The measurement that names it is two lines:

```bash
time bash -c 'printf x > results/<node>/.probe'        ## 0.002s
time bash -c 'printf x >> results/<node>/.slurm-view'  ## 28.192s
```

Same directory, same disk, same second. The only difference is that two
thousand nodes hold the second file open.

The failure this produces is not a slow cycle, it is a dead one, and it feeds
on itself. `snapshot_write` walks the fleet serially inside a unit with
`TimeoutStartSec=900`, so the arithmetic is the number of *unresponsive* nodes
times the recall timeout. Thirty-one silent nodes put the cycle just past the
limit; systemd killed it before the first trace line, roughly every fifteen
minutes, for ten hours. Nothing in `results/` said so — see
[the-agent-and-the-watchdog.md#whose-clock-decides](the-agent-and-the-watchdog.md#whose-clock-decides)
for why the heartbeat kept reporting a healthy watchdog throughout. And because
a node that has gone quiet is exactly a node that will not answer a recall, the
nodes the watchdog exists to re-arm are the ones stopping it from running.

The fix is on the server and is one setting: `fs.leases-enable = 0`, which stops
knfsd granting delegations at all. It is a required host setting, not a tuning
knob — see [the root README](../../README.md#required-host-settings-the-nfs-server).

What it costs is small and worth stating plainly. Leases are what the kernel
builds delegations out of, so turning them off means clients revalidate on open
instead of trusting a cached copy, which is more `GETATTR` traffic to `nfsd` and
no change to ordinary attribute and data caching. For this fleet that is a good
trade twice over: the files in question are small, and a delegation on a file
the head node rewrites every cycle was never going to be held long enough to pay
for itself. It is a global switch rather than an NFS one, so anything else on
that host using `fcntl(F_SETLEASE)` — Samba oplocks, some backup and indexing
tools — loses it too; on a head node that is usually nothing, but it is worth
checking rather than assuming. NFSv3 has no delegations and is unaffected, as
are byte-range locks, open state, and client lease renewal on v4. Existing
delegations are not recalled by the change; they lapse.

Writing to a temporary name and renaming would also avoid the recall, because a
rename does not recall. That was weighed against the two thousand extra forks a
cycle in the section above and lost on cost — a decision made before recall was
understood, and worth revisiting rather than assuming still correct.

## What a node reads

`snapshot_load` is called once per run and remembered; the answer cannot change
inside one cycle, and re-reading per gate would pay the NFS read again.

| Caller | Was | Now |
|---|---|---|
| `launch_job.sh` `node_info` | `scontrol show node` | `state`, `reason` |
| `launch_job.sh` `queued_ours` | whole-queue `squeue` | `ours` lines |
| `launch_job.sh` in-flight gate | `squeue -j <id>` | `ours` line for that id |
| `slurm-recovery.sh` entry | `sinfo -N -n` | `state`, `setter`, `when`, `reason` |
| `slurm-recovery.sh` counts | `scontrol show node` | `gres`, `cputot` |
| `slurm-recovery.sh` readiness | `squeue -w` | `job` lines |
| `slurm-recovery.sh` limits | `squeue -o %e` | `job` end epochs |

What a node still runs itself is `scontrol listjobs`, which asks the local
slurmstepds and costs the controller nothing, `sbatch`, and the `scontrol update`
that drains or resumes it. Those are a local question and two writes; none of
them is a query against a controller shared by two thousand hosts.

`tests/node-queries-test.sh` is the gate. It greps rather than runs, because the
failure it catches is a query being *written*.

### No view is not an empty queue

This is the whole rule, and it is the same one as
[sequencing.md#when-the-controller-does-not-answer](sequencing.md#when-the-controller-does-not-answer)
in a new place. `snapshot_load` returns 1, with `SNAPSHOT_WHY` naming which of
three things happened, when the view is missing, unsealed, or older than
`SLURM_SNAPSHOT_MAX_AGE_MINUTES` — three watchdog cycles by default, floored at
five minutes.

Every caller fails towards *not* acting:

- the submit guard **stops** rather than submitting on a guess, because reading
  an unavailable answer as "nothing of ours is out" is what puts two jobs on one
  node;
- the in-flight gate **keeps the marker** and archives nothing, because a job
  might still be queued;
- `drain_node` **does not drain**, because draining on an unknown state takes a
  node out on no information and overwrites an operator's reason with ours;
- `slurm_recover_node` **does not resume**, and says which node and why.

A node whose view has gone stale keeps its heartbeat and keeps saying, once a
cycle, that it cannot decide anything and which file is missing. It does not go
quiet, and it does not guess.

### The window this accepts

A view is up to one watchdog interval old, so a job submitted thirty seconds ago
is not in it. The guard before a submission is therefore no longer exact: a cycle
killed between `sbatch` returning and the marker being written can, in that
window, let the next cycle submit a second job.

That is a deliberate trade. Every job carries its own `#SBATCH --nice`, so the
duplicate queues behind rather than doubling up, and the in-flight marker tracks
one of them while the other reads as a foreign job and simply holds the node
until it ends. Paying a whole-queue listing per node per cycle to close a window
that costs one requeue is the wrong side of the arithmetic at the top of this
page.

## What moved to the head node

Three decisions were per-node queries whose data the watchdog already has in the
queue it just read. All three are now one pass over it.

**Pending jobs under `RUN_JOBS=no`.** Was two `squeue -n` per node per cycle, on
every node, whether or not anything was paused. The watchdog cancels every
PENDING job of ours fleet-wide in one `scancel` and leaves running ones to
finish. The node still traces what it can see of its own jobs, so the pause is
still visible where an operator looks first.

**Jobs held after a failed launch.** A job the scheduler gave up launching sits
PENDING at priority 0 for ever, and the node waiting on it waited for ever. The
watchdog cancels those; the node's marker then goes stale on its own schedule and
the next cycle there resubmits.

**Giving a node back.** See
[sequencing.md#getting-out-of-the-way](sequencing.md#getting-out-of-the-way) for
what the feature is. Finding a waiter meant a whole PENDING queue per node per
poll — by far the heaviest thing a node did. `get-out-of-the-way.sh` is now a
head-node library: it builds the set of nodes somebody else is queued for, once,
and cancels the job of ours running on each. The four checks that stand in front
of a `scancel` are unchanged, and the prefix is still re-read at the `scancel`
itself.

The node learns why its job vanished from a breadcrumb the watchdog leaves at
`results/<node>/.yielded`, which the next cycle reads and clears. Without it a
yield would read as "gone from the queue with no end marker", which is the same
line a crash produces.

`RUN_ARMING` is now scoped to the arming rather than ending the cycle. It has
to be: the view is what the whole fleet decides from, and a paused watchdog that
stopped writing it would stop every agent a snapshot age later.

## What was dropped rather than moved

`node_health.sh` opened with `sinfo -N -n $HOSTNAME` to decide whether it was on
a compute node. It is gone, and nothing replaced it.

It was one query per node per cycle to answer a question `EXCLUDE_NODES` and
`node_self_excluded` — both local, both above it — had already answered. Worse,
it could not tell a head node from a busy controller, so a controller that did
not reply stopped every health check on the node and said so in one line nobody
was reading. Health checking is now independent of Slurm entirely, which is the
right dependency for the thing that decides whether hardware is sound.

See [sequencing.md#a-host-that-is-not-a-compute-node](sequencing.md#a-host-that-is-not-a-compute-node)
for the two gates that remain.

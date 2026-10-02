# How the sequencer decides

`actions/launch_job.sh` is the last of the three steps `agent/node-agent.sh`
runs, on every node, every couple of minutes, and it decides one thing: whether
to put a job on this node right now. It is reached only on a node with no job
running on it -- see [the busy gate](#the-busy-gate). This page is why
it decides the way it does. The flags are in
[how-to/run-a-job-by-hand.md](../how-to/run-a-job-by-hand.md), the trace lines in
[reference/trace-lines.md](../reference/trace-lines.md), and the settings in
[reference/settings.md](../reference/settings.md).

Retry state is derived entirely from files already on disk: the newest result
file's mtime is when the last sweep ran, and the archived `.fail<N>.txt` files
are the attempt history. There is no state file to keep in sync.

## The busy gate

Nothing in this file runs on a node that has a job on it. `node-agent.sh` asks
`scontrol listjobs` at the top of every cycle, and any id at all — one of ours
or a neighbour's — ends the cycle with a single line:

```
BUSY: job(s) 130938 running here -- no copy, no health check, no submission
```

No container copy, no health checks, no submission, no drain recovery. The
heartbeat is still written, because the node is working perfectly well; see
[the-agent-and-the-watchdog.md#what-the-heartbeat-means](the-agent-and-the-watchdog.md#what-the-heartbeat-means).

The reasoning is that a node running a benchmark is a node whose measurements
are the point, and every one of those three steps is capable of perturbing them.
An rsync of a multi-gigabyte image competes for the same NFS mount and the same
page cache as the job. The health checks read `dmesg`, walk PCIe config space
and shell out to `nvidia-smi` thirty-eight times. Neither is large, and neither
has any business happening in the middle of a bandwidth measurement that a floor
in `SETTINGS` is about to judge to a percent.

It is also the simplest possible rule, and that is worth something on its own: a
cycle either did nothing and said so, or it did everything. There is no state in
which half the steps ran.

Two behaviours depended on running *alongside* a job of ours, and had to be
dealt with rather than quietly lost:

- **`MAX_JOB_HOURS`** drains a node whose own job has been running too long.
  That decision is now the watchdog's: `results/<node>/.in-flight` carries the
  submit epoch, the head node can read it over NFS, and the queue it already
  pulled for the node views confirms the job is still `RUNNING` before the drain. Same reason text, same absence of
  a `DRAIN_MARKER`, decided from the head node. See
  [when a node is drained](#when-a-node-is-drained).
- **`GET_OUT_OF_THE_WAY`** cancels a running job of ours when somebody else is
  queued for the node — which is exactly the cycle the busy gate now ends. It is
  therefore not a node-local decision: the head-node watchdog finds the waiter
  in its fleet queue snapshot, cancels our job, and leaves the node a breadcrumb
  explaining why its job disappeared. See
  [getting out of the way](#getting-out-of-the-way).

## One job at a time

A node has at most one job of ours out at any moment, and the record of it is a
local file — `results/<node>/.in-flight`, tab separated: job id, job name, run
number, total runs, submit epoch.

That file exists so the question "has this node got work out" can be answered
without asking slurmctld. It used to be answered with `squeue -n bringup-<node>`
and `squeue -n burnin-<node>`, every node, every cycle. The cycle comes round
about once a minute, so across 200 nodes that is on the order of a
thousand client invocations a minute — and `squeue -n <name>` pulls the **whole**
job table from slurmctld and filters it client-side, so the cost climbs with
both the fleet and the queue depth. Submitting one job instead of eight cuts the
depth as well: a fleet mid-sweep holds ~200 pending jobs where it used to hold
~1,600, which makes every remaining query cheaper for everyone on the cluster,
not just for this trigger.

Each cycle reads the marker and takes one of four branches. None of them costs
a query any more — the last two read the node view, and the only controller call
left anywhere in the table is the `sbatch` on the first row:

| Marker | Job running here | Result file | What happens | Controller |
|---|---|---|---|---|
| absent | — | — | pick the next eligible job and submit it | 1 — `sbatch` |
| present | yes | — | leave it alone | **0** |
| present | no | ends in a marker | job finished; clear and advance next cycle | **0** |
| present | no | no end marker, inside its window | not started yet; wait, and let recovery look | **0** |
| present | no | no end marker, past its window | [stale](#when-a-marker-goes-stale) | **0** |

Recovery looks on the waiting row for the reason in
[a queued job must not outrank a drain](#a-queued-job-must-not-outrank-a-drain),
and it too reads the view rather than asking.

"Job running here" is `scontrol listjobs`, which contacts the local slurmstepd
processes and not slurmctld — see [what the node can answer by
itself](#what-the-node-can-answer-by-itself). An inconclusive answer reads as
**still running**, never as gone: only the stale branch below may conclude a job
has ended, and it asks the controller outright.

The result file is not evidence on its own. `sbatch --output` creates it when
the job *starts*, so its existence says nothing; what says the job ended is an
end marker in it, which is the same thing `verdict.sh` reads.

### A missing result file is not a finished job

The row above that says "no end marker, inside its window → wait" was
unreachable for most of the fleet's life, and the failure is worth keeping
written down.

`verdict()` answers `NOT_RUN` for a file that does not exist, and the gate asked
"is this complete" as `VERDICT_STATUS != INCOMPLETE`. A job that is still queued
has no result file at all — `sbatch --output` creates it at *start* — so `NOT_RUN`
came back, the gate read "finished", and the marker was deleted on the first
cycle after submission. The trace said so plainly, once per submission, for
months: `finished after 39s: NOT_RUN -- no result file`.

Everything downstream then behaved exactly as designed, on a false premise:

- the node read as idle, so the survey re-offered the same job every cycle —
  and with no result file there is no mtime, so `RETRY_INTERVAL_HOURS` never
  applied either;
- the only thing left standing between that and a duplicate submission was the
  [guard before a submission](#the-guard-before-a-submission), which was then a
  full-queue `squeue` running every cycle on every node whose job had not
  started — the exact cost the marker exists to remove. One fleet's trace logs
  held 38,666 of its `no marker, but N job(s) of ours are already queued` lines;
- each time that one query came back empty because the controller was busy, a
  duplicate went out. Nodes accumulated two and three pending copies of the same
  benchmark, hours apart;
- and once such a job finally started, the marker was already gone, so the node
  read its **own** running job as somebody else's and left the node to it.

So `result_complete` excludes `NOT_RUN` as well as `INCOMPLETE`. A job with no
result file has not started, the marker outlives it, and the bounded wait below
is what eventually asks the controller. Nothing else needed changing — every
consequence above was a correct response to a wrong answer.

The general shape is worth naming, because it is not a Slurm problem: a
three-valued answer (`not started` / `running` / `finished`) was tested with a
two-valued question, and the missing case took the branch that does damage.

Serialization no longer depends on the scheduler: only one job of ours is ever
out, so ordering *is* the `BENCHMARKS` list. `#SBATCH --exclusive` stays in every
`jobs/*.sbatch` because it still does the other half of the work — it keeps
other people's jobs off the node mid-benchmark, and a GPU job landing on top of
dcgmi's stress plugins fails on buffer allocation. No job should depend on an
earlier one having finished.

This used to be `--dependency=singleton` over a shared job name. Singleton
matches on name alone, cluster-wide, so the name had to carry the hostname or a
bare `bringup` would have serialized every node in the rack against every other:
serialization by string equality, and silent about what a job would actually be
given once it ran. `--exclusive` states the real requirement — this job wants
the whole node — and additionally keeps *other people's* jobs off the node
mid-benchmark, which singleton never did.

The shared job name `bringup-<node>` stays, for a different reason: a
host-launched job submits itself, so the name is how the sequencer finds the id
of what it just launched. The foreign-job check does not use it — that matches
on job **id**, against the one in the marker.

## What the node can answer by itself

Almost everything this script needs is knowable on the node. `scontrol` has a
family of subcommands documented as contacting *the local slurmstepd processes
only, and not slurmctld*:

| Command | Answers |
|---|---|
| `listjobs` | every job running on this node — ours **and** everyone else's |
| `liststeps` | the steps within them |
| `listpids`, `pidinfo` | processes, and which job they belong to |
| `show slurmd` | the local daemon's own statistics |

`listjobs` prints a `JOBID` header and then one bare id per line. That single
command answers both questions the sequencer used to spend `squeue` on:

- **is our job still going** — is the marker's id in the list
- **is somebody else on this node** — is any *other* id in the list

The second used to be `squeue -w <node>`, which asked slurmctld for something
slurmd already knew.

**The exception is node state.** `State=IDLE|DRAIN|DOWN` and the drain `Reason`
live in slurmctld, not in slurmd — a node genuinely does not know it has been
drained, and no local command reports it.

It is also not a question this node is allowed to ask. The lazy, cached
`scontrol show node <node>` that used to answer it is gone: it was still one RPC
per node on every drain and resume path, and the same was true of the queue
questions below. All of it now arrives on NFS, in a small file the head node
writes for this node every watchdog cycle. See
[the-fleet-snapshot.md](the-fleet-snapshot.md), which is also where the rule for
a view that is missing or stale lives — it is *no answer*, and it stops the gate
rather than opening it.

Two things follow from that, and both remove work rather than adding it:

- **Nothing checks for a drain before submitting.** That check existed because
  submitting the whole list behind an operator's drain would dump it on the node
  the moment they resumed. One job is not a dump. A job submitted to a drained
  node simply pends, and the [stale branch](#when-a-marker-goes-stale) is what
  notices and reports the reason.
- **Recovery runs on the stale branch, not every cycle.** A drain Slurm set
  itself stops our jobs starting — which is exactly the symptom the stale branch
  fires on. So a node that is drained submits, waits out its grace, asks once,
  and recovers itself; a node that is fine never pays for the check.

The whole cost, per node per cycle:

| Cycle | Controller calls |
|---|---|
| job running, waiting, or nothing eligible | **0** |
| advancing to the next job | 1 — `sbatch` |
| marker gone stale | **0** |

Every row that used to carry a query now reads the node view instead, and the
one call left is the submission itself. What the fleet costs the controller is
two queries per watchdog cycle, whatever its size —
[the-fleet-snapshot.md#the-two-queries](the-fleet-snapshot.md#the-two-queries).

## Getting the job id right

The marker is only as good as the id in it, and there are two ways to learn one.

For a `.sbatch`, `sbatch` says so: the id is read out of `Submitted batch job
<n>`, matching that phrase rather than stripping trailing digits — with `-M` the
line ends `on cluster <name>`, and warnings can follow it. This path has no race;
the submitting command reports its own result.

For a **host-launched** job the tool submits itself, so the id has to be found
afterwards, and the job name is the only handle. `bringup-<node>` is shared by
every submission this node ever makes, so "the job under that name" is not a
unique answer: anything still queued from an earlier cycle matches too, and
picking the first meant the marker could end up tracking a stale job instead of
the one just launched. So the ids under the name are snapshotted immediately
before the launcher runs and again after, and the id is the difference.

If that difference holds more than one id, the launcher submitted twice. The
extras are ours by name and unwanted by definition — they would run the same
benchmark again on the same node — so they are cancelled and the fact is traced.

**An id that does not parse is never written down.** A marker holding an
unusable id is discarded on the next cycle by `inflight_read`, which leaves the
node looking idle while its job is still out — and it submits a second copy on
top of the first. So the id is checked before the marker is written, not after
it is read back, and a submission whose id could not be determined is traced as
a warning with the `scancel` that clears it. The node is not left silently
double-submitting; the orphan reads as somebody else's job once it starts, which
holds the node until it ends.

Nothing confirms the id is *running* at submit time, and nothing should: a job
is `PENDING` for anything from a second to hours after `sbatch` returns, so
"not running yet" is the normal case rather than a fault. Confirmation is the
next cycle's `listjobs`, and a job that never appears is caught by the
[stale branch](#when-a-marker-goes-stale) once its walltime and grace are up.

## Submitting only to an idle node

Slurm accepts a job for a node it has no intention of running it on. A drained
node, one held in a reservation, one that has stopped answering — `sbatch`
returns a job id for all of them, and the job sits `PENDING` until somebody
clears the state. Nothing here is wrong about that: the in-flight gate believes
a queued job and waits, the retry window never opens because there is no new
result, and the node is correctly reported as needing an operator.

What it costs is the queue. One drained node is one pending job that never
moves; a rack taken out for maintenance is eighteen, and they are in every
`squeue` anyone on the cluster runs, indistinguishable from work that is about
to start. The fleet does not need them: the same node is offered the same job
again next cycle, at no cost, for as long as it takes.

So `SUBMIT_ONLY_WHEN_IDLE` — on by default — checks the node's state before
`sbatch`, and the check is **exactly** `idle`. Not a prefix match, because
`sinfo` appends flag characters to the state it prints (`*` not responding, `~`
powered down, `@` pending reboot, `$` reserved for maintenance), and `idle*` is
a node that has stopped answering — the one case where a submission is most
certainly wasted. `mixed` and `allocated` are somebody else's job and are also
not submitted to, which the [busy gate](#the-busy-gate) mostly catches first
from the node's own slurmstepds; this catches the rest.

The state comes off the node view the watchdog already wrote, so the gate costs
nothing — no query, and one more read of a file this cycle has read anyway. It
is a site switch and not a timing gate, so `--force` does not lift it; see
[site switches are not timing gates](#site-switches-are-not-timing-gates).

Two cases are deliberately not blocked. A view that did not load is not a state,
so this gate says nothing and the [guard below](#the-guard-before-a-submission)
stops the cycle on the same fact with a better message. And a node this cycle
resumed reads as drained in a view written before the resume — submitting on the
state the node has *now* is right there, and the trace says that is what
happened.

The window this leaves is the view's age: a node drained seconds ago still reads
`idle` for up to one watchdog interval, and gets one pending job. That is the
same trade as everywhere else here — see
[the-fleet-snapshot.md#the-window-this-accepts](the-fleet-snapshot.md#the-window-this-accepts).

## The guard before a submission

The marker says whether a job is out, and the marker is a file. A file can be
absent while a job is not: a cycle killed between `sbatch` returning and the
marker being written leaves one, and so does a marker deleted by hand. At that
moment the job is `PENDING` — invisible to `scontrol listjobs`, which sees only
what is running — so the node looks idle and would submit a second copy.

So immediately before submitting, the node view's `ours` lines say what the
controller is holding under this node's two job names. Anything at all means
something of ours is already out, and nothing is submitted: the orphan is
untracked, so it is left to finish rather than cancelled, and the trace names it
and the `scancel` that would clear it.

That answer used to be a whole-queue `squeue`, made by every node on every cycle
that reached a submission — the single most expensive thing in the design, and
the reason [the-fleet-snapshot.md](the-fleet-snapshot.md) exists. The same lines
serve every node's duplicate-submission guard.

The guard is no longer exact, and that is a decision rather than an oversight. A
view is up to one watchdog interval old, so it cannot see a job submitted
seconds ago, and the narrow window this leaves open — a cycle killed between
`sbatch` returning and the marker being written — can let a second copy through.
Every job carries its own `#SBATCH --nice`, so the duplicate queues behind
rather than doubling up, and the one that is untracked reads as a foreign job
and holds the node until it ends. The cost of closing that window was a full
queue listing per node per cycle, for ever. See
[the-fleet-snapshot.md#the-window-this-accepts](the-fleet-snapshot.md#the-window-this-accepts).

What has *not* changed is the direction of failure: a view that is missing or
stale stops the submission rather than allowing it. Reading "I could not find
out" as "nothing of ours is out" is precisely what puts two jobs on one node.

## Submission limits belong to Slurm

The sequencer prevents duplicate work on each node, but it does not implement a
fleet-wide submission throttle. Configure that policy in Slurm, where it is
atomic and applies to every submission path charged to the association. This
requires both `MaxSubmitJobs` on every association the framework uses and
`AccountingStorageEnforce=limits` in `slurm.conf`; a value visible in `sacctmgr`
is not enforced without the second half. [Configure and verify both](../how-to/configure-slurm-submission-limits.md)
before enabling a large fleet.

Choose the value as a site policy. The framework does not maintain a second,
racy count from periodic queue snapshots.

## When the controller does not answer

A saturated slurmctld does not return an error; it returns **nothing**. `sinfo`
exits 0 with empty output, `scontrol show node` prints nothing, and `sbatch`
fails with `Socket timed out on send/recv operation`. This is observed, not
hypothetical — a fleet of ~2,000 nodes each asking five times a minute produced
981 nodes concluding `not known to slurm (sinfo -N -n returned nothing)` in a
day, which is a node deciding it had been removed from the cluster because the
controller was busy.

The rule is that **no answer is never treated as an answer**. Every question
that can come back empty has a caller that fails closed:

- **The local running check.** An inconclusive `scontrol listjobs` reads as
  *still running*, never as gone — see [one job at a time](#one-job-at-a-time).
  This is the one question a node still asks anything, and it asks its own
  slurmstepds.
- **Everything the controller knows.** The node state behind a drain, whether a
  marker's job is still queued, what is queued under our names, what is assigned
  to this node — all of it is read from the node view now, and all of it has the
  same third answer. A view that is missing, unsealed or stale is *no answer*:
  `drain_node` refuses, the stale branch keeps its marker and archives nothing,
  and the submission guard stops. See
  [the-fleet-snapshot.md#no-view-is-not-an-empty-queue](the-fleet-snapshot.md#no-view-is-not-an-empty-queue),
  which is where each of those branches is set out.
- **The watchdog's own queries.** `sinfo` returning empty is a busy controller,
  not an empty cluster, so the watchdog arms nobody and — importantly — rewrites
  no views. Every node keeps the one it has until it ages out, rather than two
  thousand views being blanked at once.

`SNAPSHOT_LOADED` separates "not read yet" from "read and unusable", so a cycle
that found no view does not go back to the share on every subsequent gate, and
`SNAPSHOT_WHY` carries which of the three it was into the trace.

This is a large part of why the call count mattered at all. The load and the
wrong answers were the same problem: the queries that saturate the controller
are the queries that then come back empty and get believed. Two queries a cycle
for the whole fleet does not saturate anything.

## When sbatch refuses a submission

An `sbatch` failure is not a benchmark failure. There is no running job, no
result file whose mtime can enforce `RETRY_INTERVAL_HOURS`, and no job id for the
in-flight marker. Retrying on the next two-minute agent cycle would make every
eligible node hammer the same unhealthy controller again.

Each node therefore writes `results/<node>/.submit-retry` with the attempted
job and run, failure count, exit status, bounded diagnostic, failure epoch and
next eligible epoch. The retry upper bound starts at
`SUBMIT_RETRY_BASE_MINUTES`, doubles after each failure and stops at
`SUBMIT_RETRY_MAX_MINUTES`. A stable hash of node, job, run and attempt chooses a
delay from the upper half of that bound; the timer's `RandomizedDelaySec` adds
the sub-cycle spread. Successful submission removes the marker.

A client timeout is ambiguous: Slurm can accept a job and lose the reply. An
elapsed backoff is therefore not enough. The node also requires a usable fleet
snapshot stamped after the failed attempt, then runs the ordinary queued-job
guard. If the controller did accept it, the guard sees the job name and refuses
to submit a duplicate. Missing, stale, or older views keep the retry closed.

The watchdog also groups recent `.submit-retry` records by their diagnostic. If
at least `SUBMIT_CIRCUIT_FAILURES` nodes report the same text within
`SUBMIT_CIRCUIT_WINDOW_MINUTES`, it writes `results/.submit-circuit`. Every node
honours that shared hold for `SUBMIT_CIRCUIT_HOLD_MINUTES`; `0` disables this
fleet-wide layer. The hold is bounded and self-clearing, so a stopped watchdog
cannot leave submissions disabled forever.

This circuit limits refused RPCs, not accepted jobs. `MaxSubmitJobs` remains the
atomic Slurm policy for pending plus running work, and should still be enabled
as described in [configure Slurm submission limits](../how-to/configure-slurm-submission-limits.md).

## A host that is not a compute node

The head node runs the framework and is not a target of it. But it is a host
with a hostname, an agent armed there will happily cycle, and nothing about
`launch_job.sh` knew that: it created `results/<headnode>/`, wrote a trigger log,
surveyed the benchmark list and reported a full row of `NOT_RUN` for ever. Every
gate it passed, it passed correctly. There was simply no gate for *this host is
not a compute node*.

The tempting test is the one this tree already threw away. `sinfo -N -n
<host>` returning nothing does mean "Slurm has never heard of it" — and it also
means "the controller is busy", which is what produced the 981 nodes above. A
head-node check built on it would be the same bug wearing a different hat, and
worse: the failure is a real node quietly retired from the fleet. An untested
node that reports nothing looks identical to a healthy one nobody asked about,
which is the silence this whole design exists to prevent.

So the question is asked of the host itself, of systemd, which answers from
installed unit files and contacts nothing over the network:

> Is `slurmctld` installed here, and `slurmd` not?

Both halves are required, and that is the point. A compute node never runs the
controller, so the first half alone already separates the two roles; the second
half means a node whose `slurmd` unit is momentarily unreadable still does not
qualify. If `systemctl` is missing, or answers with neither unit, the host is
treated as an ordinary node — no answer is not an answer here either. The cost
of a false positive is a node silently dropped from the sweep, and the cost of a
false negative is one head node in a report, so the test is built to fail
towards the second.

### Why it is written down rather than re-asked

The reports run **on** the head node, over `results/*/`, and cannot ask another
host's systemd any more than they can trust `sinfo`. So the host that can answer
the question records the answer: `launch_job.sh` writes
`results/<node>/.not-a-compute-node`, holding the reason, and the four scripts
that walk `results/` skip a directory that has one. A cycle that does *not*
match removes the marker, so the mistake is self-correcting in one direction and
one file's deletion in the other.

`EXCLUDE_NODES` is the same statement made deliberately, from the head node, and
it does not wait for a cycle to run on the host before it takes effect. Neither
`--test` nor `--force` opens it: they exist to override *timing* gates, and this
is not one — there is nothing on the other side of it to force. See
[reference/settings.md#hosts-that-are-not-compute-nodes](../reference/settings.md#hosts-that-are-not-compute-nodes).

None of it is silent. The excluded host's own `trigger.log` carries the `EXIT:`
line naming which of the two decided it, `check_trigger-log.sh --include-excluded`
still reads it, and every report prints one line naming the hosts it left out. A
row that disappears with no reason given is not distinguishable from a node
nobody ever registered, which would trade one reporting bug for a worse one.

## Cadence is per job, not per node

A job is eligible when it has not passed and its own result file is missing or
older than `RETRY_INTERVAL_HOURS`. There is no node-wide gate any more.

This is what lets one-at-a-time stay fast. Eight different benchmarks are each
eligible the moment the node is free, so the sweep advances as quickly as jobs
finish — one agent cycle of idle between them, not one hour. Meanwhile no single
job can re-run inside the hour, which is the property the node-wide gate existed
to provide. A node failing everything still submits eight jobs an hour, exactly
as before.

Order comes from `BENCHMARKS` itself: the first eligible name in the list is the
one submitted. `BURNIN` is considered only when nothing in `BENCHMARKS` is
eligible. `#SBATCH --nice` no longer orders our own jobs against each other —
there is only ever one — and now matters only against work submitted by hand or
by other users. See
[reference/jobs.md#queue-priority](../reference/jobs.md#queue-priority).

A job passes when every one of its runs ends in `DONE`; anything else — `FAIL`,
truncated output from a crashed node, or no result at all — is offered again
once its window is up. There is no retry limit: a node keeps being re-tested
until it passes or an operator intervenes.

A run is skipped at submit time when `verdict()` returns `DONE` for its result
file. What makes that skip safe is that the verdict is derived from the log on
every sweep and never read from a marker the job wrote at run time. When each
sbatch judged itself and wrote `DONE`, the skip froze that judgement: the fix
for the `-nonvlink` jobs running over TCP was correct, deployed, and
structurally unable to re-examine a single one of the results it was written
for. See
[verdicts-and-the-cache.md](verdicts-and-the-cache.md).

A job counts as *attempted* when any of its archives exist, not only when a
current result file does — either suffix, since a `.prev<N>` is a pass moved
aside and is even less untested than a `.fail<N>`. A job mid-retry with its
output rotated away is tested, and reading it as untested would hold the
swept-clean condition on the drain below open indefinitely on exactly the node
that keeps failing.

## Backing off a job that keeps failing

`RETRY_BACKOFF` widens that per-job window as a job's failures accumulate:
`RETRY_INTERVAL_HOURS`, plus one hour for every failure already on disk, up to
`RETRY_BACKOFF_MAX_HOURS`. At the shipped values a job that will not pass is
retried after 1h, then 2h, then 3h, and settles at 12h — thirteen attempts in
the first day rather than twenty-four, and two a day after that.

It ships **on**, and `settings.sh` backfills the key, so a site whose `SETTINGS`
predates it gets the ramp on the next tarball drop without editing anything —
worth knowing, because the first thing that changes is the cadence of a node
that has been failing for a while. `RETRY_BACKOFF=no` in `SETTINGS` puts the
flat window back.

An hour at a time rather than doubling, deliberately. A doubling schedule is
past a full day by the sixth failure and would need the cap to do all the work;
a linear one is legible from the log without arithmetic — the *n*th attempt
waited *n* hours — and reaches the ceiling in a number of failures you can count
on your fingers. The ceiling is what bounds the wait; the ramp only decides how
fast a node stops being interesting.

**The count comes from the archives, not from a counter.** A run's failures are
the `<job>.fail<N>.txt` files next to its result, plus the failed result
currently in place. Nothing new is written and nothing has to be cleared:
emptying `results/<node>/` by hand is a supported way to start a node over — see
[how-to/reset-results.md](../how-to/reset-results.md) — and it resets the
backoff along with everything else, because there was never a second place
holding the number. A `.prev<N>` is a *pass* moved aside by `--all` and is not
counted, so re-sweeping a healthy fleet does not slow its retries down.

Three things it deliberately does not do:

- **It never gives up.** Backoff is a wait, not a limit; the retry loop still
  has no end. Whether a node comes out of service is
  `DRAIN_AFTER_FAILED_BENCHMARK` and the drain window, which is a separate
  decision about the *node* rather than about how often to re-ask. Neither reads
  the other, and the drain still fires on a failure newer than
  `DRAIN_WINDOW_MINUTES` whenever one arrives.
- **It does not idle the node.** Cadence is per job, so a benchmark waiting out
  a 12h window does not hold up the seven that are not — the sweep advances
  through everything else at full speed, and only the job that keeps failing
  slows down.
- **It does not survive `--force`.** A backed-off window is a timing gate like
  any other, so an operator can ignore it; `RUN_JOBS` is a site switch that
  `--force` does not open. See
  [site switches are not timing gates](#site-switches-are-not-timing-gates).

A held job is traced once a cycle, both lists on one line — `backing off:
allreduce run 1 after 4 failures: 4h window, 137m left`. Without it a job in a
12h window is indistinguishable in the log from one nobody listed. A
`RETRY_BACKOFF_MAX_HOURS` that is not a whole number of hours at or above
`RETRY_INTERVAL_HOURS` is refused with a warning and the flat window kept: a
typo in `SETTINGS` must not be able to stop the fleet, and a cap below the base
interval would shorten every retry rather than lengthen it.

## Two lists

`BENCHMARKS` is the sweep and always runs. `BURNIN` runs when `RUN_BURNIN` is
on. Both are surveyed every cycle, and both submit under their own job name —
`bringup-<node>` and `burnin-<node>`.

They are separate lists rather than one longer `BENCHMARKS` because they answer
different questions on different timescales — *does this node work*, in minutes,
and *does it keep working*, in days.

The names no longer separate two queues, because there is no queue: with [one
job at a time](#one-job-at-a-time) a node has a single slot, and the marker says
whether it is taken. What they still do is label the submission — which is how a
host-launched job's id is found, and how anyone reading `squeue` by hand tells a
burn-in from a benchmark.

Ordering between the lists is now sequence rather than priority: `BENCHMARKS` is
offered first, and `BURNIN` is considered only when no benchmark is eligible. A
benchmark that comes due mid-burn-in therefore waits for the burn-in *run* in
flight to finish — up to `MAX_JOB_HOURS` — and then goes next, rather than
waiting out all twelve. That is the same guarantee the `--nice` tiers used to
buy, arrived at without queueing anything.

Burn-in used to be gated behind a clean sweep, which made the ordering absolute
at the cost of making it rigid: a node failing one benchmark could never start
burning in, and a node three days into a burn-in could not pick up a benchmark
retry until it finished. Neither is true now. The one thing this cannot do is
interrupt a *running* burn-in; that needs Slurm preemption
(`PreemptType`/`PreemptMode`, with the two lists in different partitions or
QOSes), which is scheduler configuration and not something this script can
arrange.

A job in flight is not judged: its result file is being written right now, and a
file with no end marker is a job in progress rather than one that died. Nothing
is archived, requeued or drained on until the marker clears. `quick-view.txt`
shows those as `IN QUEUE`.

A burn-in failure drains with `burn-in` in the reason, because a node that ran
for hours and then stopped is a different finding from one that failed a
collective in fifteen minutes.

With `RUN_BURNIN=no` — the default — nothing burns in, and `BURNIN` jobs appear
in `quick-view.txt` as `BURN-IN OFF` so a burn-in that never ran cannot be
misread as one that passed.

## Burn-in

Each job in `BURNIN` still uses the generic `totalRuns=N` mechanism, but
`totalRuns` is a per-job ceiling now, not the completion signal — `BURNIN_HOURS`
is. Every cycle, the sequencer picks the eligible job (under its own `totalRuns`
cap, not inside its retry window) with the **fewest passed runs so far**, ties
broken by the job's position in the `BURNIN=` line in `SETTINGS` — never by
name, or two jobs tied at zero passed would sort alphabetically instead of by
list position. With one job in `BURNIN` this is exactly today's behaviour; with
more than one, they alternate rather than one running to its own cap before the
next is ever touched. This is derived fresh every cycle from each job's current
passed count, not a persisted rotation pointer — the same reason nothing else in
this tree keeps a verdict anywhere but the result file it came from. See
[reference/settings.md#burn-in](../reference/settings.md#burn-in).

Validated hours are `passed_runs × run_length`, summed across every job in
`BURNIN`. A job's run length is read from its own `--time_to_run <N>` flag
(`mnubergemm`'s own "run for exactly this long" argument) if it has one, else
`STEP_TIMELIMIT`. `passed` means `DONE` — the gate in `verdict()` already
requires a result file's last line to be exactly `PENDING` before a job can
read `DONE` at all, so a truncated or crashed run cannot be credited hours it
did not run. Scheduling for every job in `BURNIN` stops once the shared total
reaches `BURNIN_HOURS`, whatever headroom any one job's own `totalRuns` still
has — reported as `<N>H/<BURNIN_HOURS>H`, which never collapses to a plain
`DONE` the way a benchmark column does, since the campaign target is additive
information rather than a verdict. If every job in `BURNIN` reaches its own
`totalRuns` cap before the shared total reaches `BURNIN_HOURS`, the target is
permanently unreachable without raising a cap — `launch_job.sh` traces this
distinctly rather than reading as the ordinary "nothing eligible" silence.

`report_job-status.sh`, `report_overall.sh` and `report_benchmarks.sh` no longer grow a
column per run for a `BURNIN` job — that read as up to a dozen separate
buckets for one job, which is what this section replaced. Each reports one
accumulated-hours line instead, alongside the normal benchmark columns.
`check_next-run.sh`'s burn-in row shows the earliest due time across any still-
eligible `BURNIN` job without naming which one — naming it correctly would mean
re-deriving the fairness pick above a second time in a different script purely
for a preview, which is not worth the risk of the two copies drifting apart.

## Continuous re-runs

`CONTINUE_RUNNING_JOBS` is a third list, lowest priority of the three:
considered only when both `BENCHMARKS` and `BURNIN` have nothing pending,
same rule that already governs `BURNIN` against `BENCHMARKS`. It exists for a
different question again — not *does this node work* or *does it keep
working*, but *does the answer stay the same as the cluster changes around
it* — so it trades the other two lists' notion of completion for a flat
cadence: every job here is one slot (`<job>.txt`), re-run every
`CONTINUE_RUNNING_FREQUENCY` hours once it is `DONE`, forever.  `totalRuns` is
read by `job_launcher` like any other job but never consulted here — there is
no run count to reach, only a clock, so `continue_running_next()` checks the
result file's age directly rather than walking runs the way `next_eligible()`
and `burnin_order()` do. Submissions from this tier carry the same
`bringup-<node>` job name as `BENCHMARKS` — not a third name — so
`RUN_JOBS=no` and `admin_kill-jobs.sh` both cover it without change.

The interesting case is a job listed here that is *also* in `BENCHMARKS` or
`BURNIN`, which is the intended pattern: while it keeps passing, only
`CONTINUE_RUNNING_FREQUENCY` governs it, because a `DONE` result satisfies the
higher list's own survey and that list has nothing left pending for it. The
moment a re-run fails, nothing in this tier notices or reacts — the same
result file that `continue_running_next()` was reading is now a failure in
`BENCHMARKS`' or `BURNIN`'s own survey, and because those are strictly higher
priority, `CONTINUE_RUNNING_JOBS` stops being considered *at all* until that
list's pending set is empty again, not just for the one job. Normal
`RETRY_INTERVAL_HOURS`, backoff and draining apply from there, exactly as they
would for any other failure — `CONTINUE_RUNNING_FREQUENCY` has no say in a
failing job. This needs no code of its own: it falls out of every tier reading
the same one result file per job, and priority already being checked fresh
every cycle.

A job named in `CONTINUE_RUNNING_JOBS` but nowhere in `BENCHMARKS` or `BURNIN`
has no higher-priority list to hand a failure to, so a failure there just sits
until `CONTINUE_RUNNING_FREQUENCY` comes back around — no drain, no backoff,
retried on the same flat cadence a passing run would have used. That is
usually not what was intended, so `launch_job.sh` traces a `WARNING` naming
the job once per cycle rather than let it be silently different from the
paired pattern above. See
[reference/settings.md#continuous-re-runs](../reference/settings.md#continuous-re-runs).

## Host-launched jobs

Almost every job is a `.sbatch` the sequencer submits. A job whose tool does its
own submitting is a `.sh` the sequencer *runs on the node* instead.

**No job ships as one today.** `llm-pretrain` was the only one, and it is now a
frozen `.sbatch` — [llmb.md#the-frozen-recipe](llmb.md#the-frozen-recipe). The
mechanism stays because the constraint that produced it has not gone away: any
tool that submits its own Slurm job cannot be a batch payload, for the reasons
in [llmb.md#why-llm-pretrain-is-not-an-sbatch](llmb.md#why-llm-pretrain-is-not-an-sbatch).

`job_launcher()` resolves a name to one or the other, `.sbatch` first. Both
present is traced as a `NOTE` naming the winner rather than silently dropping
one, because two launchers for one name is a half-finished conversion.

A `.sh` is only a job if it carries a line reading exactly:

```bash
job_launch=host
```

`JOBS_DIR` also holds sourced helpers — `nccl-hca.sh` — so a bare `*.sh` glob
would offer those as benchmarks and `--test` would list them. The marker is read
with `grep`, never by sourcing, for the same reason `totalRuns` is. A `.sh`
without it is traced by name (`has no 'job_launch=host' line`) rather than
skipped as missing: the file is there, so "no such job" would send the reader
looking in the wrong place.

What the sequencer hands a host launcher, in place of the `-J` and `--output` it
would pass `sbatch`:

```
SBATCH_JOB_NAME=<bringup|burnin>-<node> RESULT_FILE=<file> \
  [<site paths>] [<JOB_ENV>] bash <job>.sh
```

`SBATCH_JOB_NAME` is a real `sbatch` default, and it is also the name the
launcher is expected to put on its own submission — the queue gates on this node
match on it, so a job submitted under any other name is invisible to them.

There is no `SBATCH_OUTPUT` and no nodelist equivalent among the `SBATCH_*`
defaults, so pinning the job to this node and redirecting its output cannot be
handed over in the environment. They are the launcher's job, using whatever its
own tool provides — for `llmb-run` that was `--nodelist` and `--slurm-arg`. See
[llmb.md#pinning-the-submission](llmb.md#pinning-the-submission).

Site paths, including `LLM_HF_HOME`, go through the same allowlist as `JOB_ENV`,
and for the same reason: the submission is a string handed to a shell, so an
unvalidated `SETTINGS` value runs on every node as whatever the cycle is. See
[reference/settings.md#what-is-rejected](../reference/settings.md#what-is-rejected).

Success is **not** taken from the launcher's exit status. A tool can exit `0`
having submitted nothing, and one that passes its own `--job-name` overrides
`SBATCH_JOB_NAME` and leaves a job every gate on the node reads as somebody
else's. So the marker is written with the id `pending` rather than a number, and
the first node view carrying exactly one job under this node's names fills it
in. More than one is ambiguous and none is adopted — the wrong id in a marker
pins the node to somebody else's job, which is worse than waiting another cycle.
A launcher that exits non-zero is traced as `SUBMIT FAILED` with its output.

## Nothing is read by sourcing it

`totalRuns` is read out of the job file with `grep` — first line that mentions
it, everything right of the `=`, whitespace stripped. A job file is a script,
and sourcing one here would run its body in the sequencer's own shell, as root,
on every node on every cycle. A value that is not a positive integer
falls back to `1` rather than to nothing, so a typo costs coverage rather than
the whole job. The `job_launch=host` marker above is read the same way, for the
same reason.

A name in `BENCHMARKS` or `BURNIN` with no launcher behind it drops out of the
sweep entirely: it never goes pending, so it never blocks the node and never
surfaces as missing. That is the silent-nothing this tree exists to prevent, so
the survey traces `skip <job>: no <path>` for it, and `--all` re-queues from
what the survey found rather than from the configured list — a forced sweep
cannot pend a job that has nothing to submit.

## Retry and drain behaviour

The script runs on every agent cycle, so the hourly cadence needs no cron and no
second timer — just a time gate.

### When a marker goes stale

A marker whose job is neither running here nor finished is either queued behind
somebody else's work, held, cancelled, or gone with the node under it. Locally
those are indistinguishable — all you see is a marker getting older — and
guessing wrong is expensive in both directions: resubmit too eagerly and the
node runs two copies of a job whose result is meant to judge the hardware; wait
forever and the node is silently idle, which is the failure this whole tree is
built to prevent.

So the wait is bounded by `INFLIGHT_GRACE_MINUTES` (default 30). Too low and a
node queued behind somebody else's long job gets asked about every cycle; too
high and a job that died leaves the node idle for that much longer. It is the
only setting that trades those two against each other.

It used to add the job's own `#SBATCH -t` on top, on the reasoning that one
fixed window could not serve both `dcgmi-r1` at 25 minutes and `mnubergemm` at
six hours. That reasoning does not survive contact with the question being
asked: how long a job would *run* says nothing about how long it may sit
*queued*, and the two cases below have immediate answers that were being waited
out. On `mnubergemm` the wait was seven hours.

Past that bound, and only then, the node view's `ours` lines settle it:

- **Still in the queue** — left alone, and the trace names the state, the reason
  and what would give up on it. Queued behind a long foreign job is a legitimate
  state, not a fault. The trace says `scancel <id> && rm <marker>` rather than
  just `scancel`: cancelling the job leaves the marker, and the marker is what
  pins the node — an operator who ran only the first half watched the node stay
  put and reasonably concluded the advice was wrong.
- **Not in the view** — gone without finishing. The partial result is archived
  as `.fail<N>.txt` so the slot is free and the attempt is still on disk. If the
  watchdog left a `.yielded` note the trace says that instead, because a node
  given up to a waiter and a node whose job crashed produce the same silence
  otherwise.
- **No usable view** — the third answer, and the marker is kept. Nothing is
  archived and nothing is resubmitted, because "I could not find out" must not
  read as "gone".

A job held after a failed launch used to be cancelled here. It sits at priority
0 and never starts, so waiting on it waits forever — but finding it cost the
`squeue -j` this branch was built around, and the watchdog now cancels every one
of them fleet-wide from the queue it already has. This node simply reads "still
queued" until the job disappears, then takes the branch above. See
[jobs the scheduler has given up on](#jobs-the-scheduler-has-given-up-on).

### A queued job must not outrank a drain

The in-flight gate returns before everything below it, recovery included. That
is right for a node that is busy and wrong for a node that is stuck, and the two
were indistinguishable from inside the gate:

```
node drained  →  our job cannot start  →  gate sees a job in flight  →  exit
                        ▲                                                │
                        └──────── the recovery that would clear it ──────┘
```

The node writes a `waiting` line every cycle and does nothing, for as long as
the bound above allows. Every ingredient of that deadlock is a correct decision:
one job at a time, believe the marker, don't ask the controller on a quiet node.

So `recover_slurm_drains` is a function, called from the gate's waiting paths as
well as after it, and it runs at most once a cycle. It costs the controller
nothing at all now — the state and reason it needs are already in the node view
this cycle read.

The exception it keeps: a job of *ours* **running** on the node means the node
is working, and its drains are not ours to clear. That case still exits above
recovery, as it always did.

### When a node is drained

`MAX_JOB_HOURS` is checked against the marker rather than against `squeue`: a
job still running here past that limit drains the node, which is the one branch
that reads on past the in-flight gate, because a drain needs the node state.

The node is drained **only after a full sweep** — every benchmark has run at
least once and something is still not passing. A single failure mid-sweep does
not drain, so the rest of the sweep still runs and one bad test does not hide
the state of the others.

Drains fire only on failures that **just happened** — results newer than
`DRAIN_WINDOW_MINUTES` (default 15). Stale result files never trigger a drain,
so a node you resume by hand is not immediately pulled back out of service; it
takes a fresh retry sweep failing again. Without that window, `launch_job.sh`
would re-drain from stale result files on every cycle.

The drain reason carries an `auto-retry` marker, and only drains carrying that
marker are ever cleared. A node drained by an operator is never auto-resumed,
and nothing is queued behind their drain.

The reason field carries *why* the first failing job failed, not just its name:
a Slurm reason is one short field and there may be several failures, so the rest
— and the full text for every one — stay in `trigger.log` and `quick-view.txt`
next to the results. When the failures are burn-in only, the reason says so,
because the two mean different things to whoever is reading `sinfo -R`: a
benchmark failure is a node that does not work, and a burn-in failure is a node
that worked for hours and then stopped, which should not be reported as if it
had failed a fifteen-minute collective.

`DRAIN_AFTER_FAILED_BENCHMARK=no` disables every drain this script issues,
including the `MAX_JOB_HOURS` timeout one. Testing is unchanged — results are
still recorded, failures still retry hourly — the node is simply never taken out
of service. The suppressed drain is still traced, so the log answers "what would
this have done" for a site running with drains off.

```
sweep runs → all pass            → burn-in if RUN_BURNIN, else idle + all DONE
sweep runs → some fail           → drain "<jobs> FAIL (auto-retry)"
             +1 hour             → resume, archive failures, re-queue them
             fails again         → drain again, repeat indefinitely
```

A job running longer than `MAX_JOB_HOURS` drains the node with a timeout reason.
That reason carries no marker, so a stuck job stops the retry loop and waits for
a human. Only a `RUNNING` job is measured against that limit — a batch queued
behind a dead node reads `0:00` for as long as it waits, and draining the node
for "timeout" would only bury the real reason it is unusable.

**That one is issued by the watchdog**, not by the node: the node's own cycle
stops at [the busy gate](#the-busy-gate) while the job it would be measuring is
still running. `agent/supervisor.sh` reads the submit epoch out of every
`results/<node>/.in-flight`, looks up the ids already past the limit in the queue
it read for the node views, and drains the nodes whose job is still `RUNNING`. The gate in
`launch_job.sh` stays, because a hand-run still reaches it and it is the same
decision from the same marker.

### Drains Slurm set itself

Before any of the gates above look at the node state, a drain that is Slurm
talking to itself — a failed prolog, a rogue process left by the previous job,
an empty reason — is cleared and the state re-read, so the rest of the cycle
runs against a node that is back in service. Without it every gate below reads
such a node as unusable and stops, correctly and permanently, since nothing here
ever cleared a drain it did not set.

The sequencer accepts only the `machine` class. A health-check drain belongs to
`node_health.sh`, which is the only thing that knows whether the check passes
now; the framework's own `auto-retry` drain is cleared by the sweep when the
benchmarks pass; an operator's drain belongs to the operator. All of that is in
[drain-recovery.md](drain-recovery.md).

The recovery runs **above** the `RUN_JOBS` gate and answers to
`RUN_RECOVERY` instead. Under `--explain` it classifies and reports and issues
nothing.

### Jobs the scheduler has given up on

A failed launch — slurmd not answering at the moment the scheduler tried to
start the job — does not fail the job. Slurm requeues it and *holds* it, and a
held job reads as `PENDING` to the name queries above while carrying priority 0:
it will never start, however healthy the node later becomes. Left alone, the
marker pins the node until its walltime and grace are up, every cycle.

So a job of ours held with reason `launch failed requeued held` is cancelled and
left to the survey to re-queue. **The watchdog does this now**, not the node: it
was the node's own `squeue -j` that found the held job, and that query is gone.
The head node sees every held job of ours in the one queue it reads each cycle,
and cancels them together.

What makes that cancel safe is the name. Only a job whose name begins `bringup-`
or `burnin-` is ever touched — the same prefix gate as the yield path, and for
the same reason: the watchdog is acting on the controller's own answer about
jobs it did not submit itself, so nothing may be taken on trust. The node's
marker is not consulted and is not evidence.

Two bounds on it:

- **An operator's hold is never cancelled.** `JobHeldUser` and `JobHeldAdmin`
  are the same `PENDING`-at-priority-0, but a person chose it. The match is on
  the `launch failed requeued held` reason, so those are left alone.
- **Nothing bounds how often this repeats, and it should.** The hourly gate
  keys off result mtime, and a job that never ran writes no result, so that gate
  stays open: once the cancel lands, the node's marker goes stale and the next
  cycle submits again. The only thing pacing the loop is
  `INFLIGHT_GRACE_MINUTES`, which is how long the marker survives before the
  node notices its job has gone. A node that cannot launch anything will
  therefore cancel and resubmit indefinitely, at roughly one cycle per grace
  window. This is a known gap, not a design: see
  [what the traces showed](#what-the-traces-showed).

#### What the traces showed

On 2026-08-08, when this cancel still ran on each node, `trigger.log` across the
fleet held **31,270** `CANCELLED … held after a failed launch` lines and nothing
else — no yields, no other cancel of
any kind. Every one named a benchmark of ours, and the ids matched what `sbatch`
had returned, so nothing belonging to another tenant was ever cancelled. What
the volume showed was the unbounded loop above: nodes that could not launch,
resubmitting for as long as they could not launch.

Two things are worth separating when reading a pile of those lines. The cancel
is working as designed — a held job that will never start is not worth waiting
on. The *rate* is the fault, and it is a symptom: `launch failed requeued held`
means `slurmd` did not answer when the scheduler tried to start the job, which
is a node or prolog problem, not a sequencer problem. Chase it with `sacct -j
<id> -o JobID,JobName,State,Reason` and the failed-prolog logs under
`RECOVER_PREJOB_LOGS`.

The scheduler's reason for any job of ours that is not cleanly schedulable is
appended to both the `queue:` line and the `EXIT: waiting on our own queue`
line. `waiting on our own queue` reads identically whether the job starts in a
minute or never starts at all, and the reason is the whole difference.

## What a pause is for

The pause switches stop the framework *doing* things without disarming it. The
timers keep firing and each step still runs — it reads its switch, does nothing,
and says so. That is deliberate: a disabled timer looks exactly like a broken
one, and the state is only visible from the node. A pause leaves a trace line on
every node saying it is paused, and
`check_trigger-debug.sh` reports it in section 0 before it walks any of the links.

Nothing is lost across a pause. Results stay on disk, the sweep resumes from
where it stopped rather than restarting, and a `refresh` sentinel set by
`report_health.sh --refresh` is held rather than consumed.

`RUN_JOBS=no` also reaches work already in the queue, because gating submission
alone would leave hours of already-queued benchmarks running:

| | What happens |
|---|---|
| Pending jobs (ours) | Cancelled. They have produced nothing, and the next unpaused sweep queues them again. |
| Running job (ours) | Left to finish, with its job id traced. Killing it turns a part-written result into an `INCOMPLETE` that is indistinguishable from a crash. `scancel <id>` if you need the node back now. |
| Anyone else's job | Untouched. Only jobs named `bringup-<node>` or `burnin-<node>` are ever cancelled. |

`RUN_CONTAINER_COPY=no` likewise stops new copies and lets a detached `rsync`
from an earlier cycle finish — it holds no node and blocks no job.

`RUN_RECOVERY` is independent of `RUN_JOBS`, and the two answer different
questions. Stopping the sweep is "put no more work on this cluster"; stopping
the recovery is "leave every drain where it is". Those are separate decisions
and usually made for separate reasons — during a bring-up you often want the
drains cleared while nothing is being submitted, and during an investigation you
want the opposite. So the recovery runs above the `RUN_JOBS` gate in
`launch_job.sh`, governed only by its own switch: putting a node back is not
putting work on it.

`node_health.sh` honours `RUN_RECOVERY` too, though its own recovery is
reachable only after a clean check run — so `RUN_HEALTH_CHECKS=no` stops that
one as a side effect, for want of the evidence rather than for want of
permission.

### `--explain` reads through a pause

`launch_job.sh --explain` is stopped by **neither** `RUN_JOBS` nor
`RUN_RECOVERY`. It writes nothing to Slurm and nothing to disk beyond its own
trace, and "what would this do on this node" is a question worth being able to
ask *precisely* when the thing is stopped — while you are looking at a list of
drained nodes deciding whether to lift the pause. It reports each pause it
passes, then carries on:

```
RUN_RECOVERY=no in /cluster/bringup/SETTINGS -- explaining anyway; nothing below would be resumed while it is set
RUN_JOBS=no in /cluster/bringup/SETTINGS -- explaining anyway; nothing below would run while it is set
WOULD RECOVER ink50-dh01-h03-16: drained 'Prolog error' (machine, set by slurm) -- attempt 1/3 in 24h
```

Under `--explain` the recovery runs with `RECOVER_DRY_RUN=1`, which issues no
`scontrol`, restarts no `slurmd`, and records no attempt against
`RECOVER_MAX_ATTEMPTS` — so `RUN_RECOVERY` has nothing to protect it from.

`--force` is refused instead, and that asymmetry is the point: `--force` would
touch the cluster, `--explain` cannot.

## The sweep is shaped like a backfill job, and that is load-bearing

Nothing here sets out to be a good scheduling citizen, but three independent
decisions add up to one: **every job is single-node, short, and low priority.**
That is precisely the profile Slurm's backfill pass exists to place.

| Decision | Made for | Backfill consequence |
|---|---|---|
| `-N 1 --exclusive` | a benchmark sharing a node measures the other job | fits gaps a multi-node job cannot |
| `#SBATCH -t` derived, not padded | the step limit must fire before the job walltime, so a marker gets written | the limit is honest, so it fits real gaps |
| `--nice=20` / `100000` | leave `0` free for a job submitted by hand | low priority is what makes a job *eligible* for backfill |

Backfill starts a lower-priority job early when doing so does not delay the
expected start of any higher-priority job. A 25-minute single-node benchmark
slots into the idle time ahead of somebody's 32-node reservation without moving
it, so the sweep progresses on a cluster that is nominally full.

One consequence matters more than it looks:

- **Padding a walltime costs coverage, not just clock.** A job whose `-t` is
  generous stops fitting gaps and starts waiting for reservations instead. That
  is the second reason the limits in
  [reference/jobs.md#what-each-jobs-limits-were-derived-from](../reference/jobs.md#what-each-jobs-limits-were-derived-from)
  are derived per job rather than set to one safe large number — the first being
  that `MAX_JOB_HOURS` has to clear the longest of them.

It also explains a report that arrives periodically and is not a bug: a
`burnin-*` job at `--nice=100000` starting while somebody's higher-priority job
waits. Priority orders competition for a node that is free *now*; backfill fills
a gap nobody is competing for. Both are working. The operator-facing version of
this is
[how-to/estimate-when-a-job-will-start.md](../how-to/estimate-when-a-job-will-start.md#6-why-our-jobs-start-ahead-of-yours-anyway).

## Getting out of the way

Backfill is what keeps the sweep polite about *starting*. `GET_OUT_OF_THE_WAY`
is the other half, and it is about *stopping*: a benchmark that is already
running holds the node until it ends, and backfill has nothing to say about a
job it has already placed. A 25-minute `allreduce` is nothing to wait for; a
seven-hour `mnubergemm` under somebody's deadline is, and the operator-facing
symptom is a job stuck behind `bringup-<node>` with no obvious owner.

**It is the watchdog's decision, and that is what made it reachable.** The
switch used to live in `launch_job.sh`, where two things were wrong with it: the
busy gate ends the cycle before the sequencer runs on exactly the node this
would act on, so it only ever fired from a hand-run; and finding a waiter meant
pulling the whole `PENDING` queue, per node, per poll — the heaviest thing any
node did. The head node already holds one queue for the fleet, and one pass over
it answers the question for every node at once. See
[the-fleet-snapshot.md#what-moved-to-the-head-node](the-fleet-snapshot.md#what-moved-to-the-head-node).

With the switch on, the watchdog builds the set of nodes somebody else is queued
for and cancels **our own** job on each. The sweep loses an attempt and re-queues
it; the node's marker goes stale on its next cycle, and the partial result is
left where it is — an interrupted run is already `INCOMPLETE`, and the
resubmission archives it as the previous attempt like any other. Nothing is
drained and nothing is counted as a failure.

The node is told why. The watchdog writes `results/<node>/.yielded`, which the
next cycle reads and clears, so the trace says the job was given up rather than
reporting it as gone from the queue — the line a crash produces. Without that
the two are indistinguishable, which is the silence this tree is against.

It ships **off**, and it is **experimental**. It is the only setting in the tree
that cancels a job of ours that is working, and a site that is the only tenant
of its cluster gains nothing from it.

Experimental means the switch is not yet load-bearing anywhere and has not run
long enough on a busy multi-tenant cluster for the polling interval, the pending
threshold or the "is anybody actually waiting for *this* node" test to have been
argued with by reality. Those are the parts most likely to move: the setting
names and the trace lines may change, and a site that turns it on should expect
to revisit its values rather than treat them as settled. What will not change is
the safety envelope — only a `bringup-<node>` or `burnin-<node>` job owned by
`JOB_USER` and confirmed `RUNNING` here is ever cancelled, and nothing is
drained or counted as a failure.

### What counts as a waiter

A pending job, not ours, that this node is part of the answer to:

| Condition | Read from | Why |
|---|---|---|
| `PENDING` | `%T` | a running job elsewhere is not waiting for anything |
| not named `bringup-*` or `burnin-*` | `%j` | another node's sweep job waiting its turn is not somebody being kept off the cluster |
| pending at least `GET_OUT_OF_THE_WAY_AFTER_MINUTES` | `%V`, against the watchdog's clock | a job that may yet be satisfied somewhere else is not worth throwing a benchmark away for |
| priority is not 0 | `%Q` | a held job is never going to start, so nothing is being kept off the cluster — see below |
| wants this node | `ReqNodes` **or** `SchedNodes` | see below |
| enough of the nodes it wants are ours to free | `%D`, against `sinfo`'s `%T` and the running half of the same queue | a job that still cannot start after the cancel got nothing for it — see below |

**A waiter is told from one of ours by its name, never by its user.** The
neighbouring work on a bring-up cluster is usually submitted by the same account
the framework runs as — a real pending job here reads
`130938|cmods|microbenchmark_nccl_nccl_fp8|ink50-dh01-i01-[11-18,28-37]`, owned
by `cmods` like everything of ours. Filtering waiters by user would make the
whole feature inert on exactly the cluster it was written for. The user check
exists on the other side of the decision, where it belongs: on the job about to
be cancelled.

Both node lists are read and they answer different questions. `ReqNodes` is
somebody naming nodes with `-w`, which is what a multi-node microbenchmark
does; `SchedNodes` is the backfill scheduler having *planned* this node into an
allocation, for a job that asked for a count rather than for names. `SchedNodes`
comes back `(null)` on a queue that has nothing planned yet, and is treated as
no match — so on a cluster where it is always empty, `ReqNodes` carries the
whole check and the feature still works.

Node lists are expanded with `scontrol show hostnames` rather than matched as
text. `ink50-dh01-i01-[11-18]` does not contain the string
`ink50-dh01-i01-13`, and a substring test against a compressed list is a check
that silently never fires.

### A held job is not a waiter

Every condition above except this one was in the original check, and the fleet
found the gap. A job Slurm requeued and held after a failed launch stays in the
queue reading `PENDING`, with a node list, ageing past any threshold — it
satisfies the whole test, and it is at priority 0, which means it will never
start no matter what this node does. Yielding to it throws a running benchmark
away and gives the nodes to nobody.

That is not a hypothetical. On 2026-08-09 seven held 18-node microbenchmarks
sat across the cluster, each naming its rack with `-w`, between them making 126
nodes read as wanted by somebody. The same failed launches are what
[jobs the scheduler has given up on](#jobs-the-scheduler-has-given-up-on)
describes from our own side; the difference is that a held job of *ours* is
cancelled and resubmitted, and a held job of somebody else's is nobody's to
clear, so it sits there for as long as it takes an operator to notice.

`%Q`, not `%p`: `squeue` reports the first as the integer priority and the
second normalised to a float between 0 and 1, and only the integer compares
cleanly against `0`. The test is for exactly `0` rather than for a reason
string, because `JobHeldUser`, `JobHeldAdmin` and `launch failed requeued held`
are three spellings of one state and Slurm's own definition of that state is the
priority. Anything unparseable is read as a real waiter: an unexpected
`squeue` build should make the feature no worse than it was, not silently stop
it yielding at all.

### A waiter that cannot run is not a waiter

The held-job gap above is one instance of a larger one, and the larger one is
the question this feature is actually asking: *would handing this node back let
that job start?* A pending job names nodes; naming them does not mean it is one
cancel away from running. If any part of what it needs is out of service, or is
held by work this framework cannot end, the benchmark is thrown away and the
job waits exactly as long as it was going to.

So a waiter's whole node list — `ReqNodes` and `SchedNodes`, deduplicated,
expanded — is counted against `%D`, the number of nodes it asked for, and a node
counts only if it is one of:

| State | Counts because |
|---|---|
| `idle` | free now |
| `allocated`, `mixed`, **carrying nothing but jobs of ours** | free the moment this cancels, which is the whole transaction |

Everything else does not count: `drained`, `draining`, `down`, `reserved`,
`maint`, a state with the `*` of a node that is not answering, a node `sinfo`
did not report at all, and — the one the states cannot answer on their own — a
node running somebody else's job. `allocated` reads the same whether the job on
the node is our `bringup-<node>` or a stranger's twelve-hour run, and only the
first is ours to end. The running half of the queue this already holds says
which, by the same name-and-user test the cancel side uses.

Fewer usable nodes than `%D` and the job is not a waiter: it is traced with what
was in the way and the scan moves on.

Two readings are deliberately strict, because the cost of being wrong is a
cancelled benchmark and the cost of being cautious is a benchmark that finishes:

- **An unparseable or empty `%D` is read as "it needs every node it named."**
  That is what a `-w` list usually means, and a job that names 18 nodes with one
  of them drained is the case this exists for.
- **A node a stranger holds is unusable even when it is minutes from finishing.**
  Nothing here can tell "ends at 14:02" from "ends tomorrow" without asking the
  controller more questions than the snapshot answers, and the safe reading is
  the one that cancels less.

The check is inert rather than guessed at when the caller passes no node states:
the scan traces that it has none and every waiter reads as able to run, which is
what it did before the states were passed in. See
[the-fleet-snapshot.md#the-two-queries](the-fleet-snapshot.md#the-two-queries)
for why `%D` is in the queue format at all.

### The four checks before a cancel

No marker is consulted, and that is the point: an id is reused after
`MinJobAge`, a marker survives a hand-run that submitted something else, and the
cost of being wrong is cancelling a stranger's work. The watchdog works from the
controller's own answer throughout, and **every** one of these has to hold
before `scancel` runs:

1. `%T` is `RUNNING` — a pending job of ours is holding nothing
2. `%u` is `JOB_USER`
3. `%j` begins `bringup-` or `burnin-`
4. `%N`, expanded, contains a node somebody else is queued for

Anything else — another user, a foreign name, a job that turns out to be
pending, a job of ours running somewhere nobody is waiting for — leaves the job
alone. A node that is wanted and was not given up is named in the trace, so
"nothing of ours is there" and "the scan never ran" do not read alike.
`scancel`'s output is read rather than its exit status, because a refused kill
is reported on stdout with a zero exit, as in `admin_kill-jobs.sh`.

### The prefix is the gate

Check 3 is the one that actually separates our work from a neighbour's, and it
is worth being explicit about why the others cannot do it.

`%u` cannot, on this cluster. The neighbouring work is submitted by the same
account the framework runs as, so check 2 passes for a stranger's job as readily
as for ours — a real running job here reads
`132500|microbenchmark_nccl_nccl_fp8|cmods|RUNNING|…`. What is left is the name,
and every job this framework submits is named `bringup-<node>` or
`burnin-<node>`.

So the prefix is checked in two places, and `get-out-of-the-way.sh` has only one
line that calls `scancel`:

1. in the scan, before a running job is considered a candidate at all
2. in `_yield_cancel`, against the prefix list again, on the name the controller
   returned, immediately before the `scancel` runs

The second is not redundant. The first is reached through a loop over the whole
queue; the second is on the only path to a cancel and depends on nothing but the
name it was handed. A name that does not begin with `bringup-` or `burnin-`
cannot reach `scancel` without that function being edited, and a refusal is
*printed*, which the caller reads as a failed cancel and traces. The wrong
outcome here is silence, not noise.

`tests/yield-test.sh` drives `_yield_cancel` directly with foreign names,
because no caller can reach it with one.

### The cancel runs as the cycle

`launch_job.sh` used to run as root, and root's `scancel` will cancel anything
on the cluster, so the cancel was handed down with `su - "$JOB_USER" -c`. The
watchdog is that account, so the `scancel` runs directly and Slurm's own
ownership check sits underneath ours by default rather than by an explicit drop.
It is not the load-bearing gate, because `JOB_USER` owns the neighbouring work
too; it is there so that the failure mode of a bug in this file is a refusal
rather than a fleet-wide cancel. See
[running-unprivileged.md#the-cancel-runs-as-the-cycle](running-unprivileged.md#the-cancel-runs-as-the-cycle).

Nothing prompts for a password, and nothing can: there is no privilege to
acquire on this path, and a `su` that could block is never reached inside a
cycle.

The checks live in `get-out-of-the-way.sh` rather than inline, so
`tests/yield-test.sh` can drive every one of them against a queue it writes by
hand. The assertions that matter there are the negative ones: each case that
must not cancel asserts that `scancel` was never called.

### What a yield costs

Nothing, now. The pending queue this reads is the one the watchdog already
pulled for the node views, so turning the switch on adds no controller traffic
at all. That was not true before: listing the pending queue is the expensive
shape — the whole job table, fetched and filtered client-side, once a poll, on
every busy node — and it is why the feature was polled rather than run every
cycle.

`GET_OUT_OF_THE_WAY_POLL_MINUTES` is kept anyway, and its meaning has changed
from a cost control to a safety one. It is enforced with the mtime of
`results/.yield-check` — one stamp for the fleet now, not one per node — written
before the scan and not at all under `--explain`. Cancelling a job that is
working is the single destructive thing this framework does, so it is worth a
rate limit whether or not it is worth a query budget. At the shipped five
minutes the worst case between somebody queueing and a node being given up is
that plus `GET_OUT_OF_THE_WAY_AFTER_MINUTES`.

## Site switches are not timing gates

`--force` opens the hourly retry gate and nothing else. `RUN_JOBS` and
`NODE_FILTER` are statements about what the cluster should be given, not about
when a job is next due, so a forced sweep is asked the same questions a normal
cycle is and each one traces that `--force` did not override it.

`NODE_FILTER` is the one most likely to be forced over by accident: `-f` is
normally issued across a whole rack at once, and it must not quietly test
nodes the site took out.

`--test` **does** open `NODE_FILTER`. Naming a job and running the command on a
particular node is already a deliberate statement about that node, which `-f`
across a rack is not, and refusing would mean widening the site's `NODE_FILTER`
to check one suspect machine. The run traces that it went ahead and that the
node is outside the swept set, so a result on a node the reports do not cover
has an explanation next to it — nothing there will be re-run on a cadence.

## The job file wins

A variable that the job's own `.sbatch` exports is **not** overridden by
`JOB_ENV`. The `export` in the job file runs after `sbatch` has handed over the
environment, so it is last to write.

That is the right way round. `allreduce-nonvlink.sbatch` has to run with
`NCCL_P2P_DISABLE=1`; a site-wide setting that could flip it would turn the
non-NVLink benchmark into a second NVLink benchmark, which passes and tests
nothing. Per-job values are the test definition, and `JOB_ENV` is the
environment around it.

What was wrong with this before it was written down is that the override was
silent — a `SETTINGS` line that did nothing looked exactly like one that worked.
`launch_job.sh` now traces the collision when it submits.

## What a submission carries

The submission is built as one string and handed to `bash -lc`, because the
cycle is already `$JOB_USER` and there is nothing to drop to. The login shell is
what puts the Slurm client tools on `PATH` — see
[how-to/run-slurm-commands-remotely.md](../how-to/run-slurm-commands-remotely.md).
It loads the `slurm` module, makes `results/<node>` if it is missing, and
submits:

```
sbatch -w $HOSTNAME -J <bringup|burnin>-<node> \
       --export=ALL,RESULT_FILE=<file>[,<JOB_ENV>],BRINGUP_HOME=…,CONTAINER_DIR=…[,LLMB_*=…] \
       --output=<file> <job>.sbatch
```

The site's paths are on that list because a batch script cannot work them out.
It runs from Slurm's spool copy, so `${BASH_SOURCE[0]}` names a file in
`/var/spool/slurmd` rather than anywhere in the tree, and there is no `SETTINGS`
to read from there. Every one of them goes through the same allowlist as
`JOB_ENV` — see [What is rejected](../reference/settings.md#what-is-rejected) —
because the whole string is run by a shell.

The job files spell these `${CONTAINER_DIR:?…}` rather than giving them a
default. A default would have to be a literal path, which is the thing that
broke when the account moved; `:?` makes a job submitted without it stop and
say which variable was missing, in the result file, where the next report reads
it.

`-J` is per list and per node, and it is passed here rather than as an `#SBATCH`
line because those are comments rather than shell and would not expand
`$HOSTNAME`. It is what the queue queries match on, so a job submitted without
it is invisible to the next cycle's "is anything of ours out there" check.
`RESULT_FILE` is where the job writes its own markers and `--output` is where
`sbatch` puts the job's stdout — the same path, which is what makes a result
file a complete record of the run.

Queue priority is deliberately not set here. Each job states its own in
`#SBATCH --nice`, alongside its time limit and its allocation, so a job
submitted by hand sits in the queue exactly where the sequencer would have put
it. This script decides only *what* to submit.

`sbatch`'s own output is captured with stderr merged and written to the trace,
successful or not. A bad partition, an unknown node name, an account limit and
`su` failing for `cmods` all land there, and all of them look identical from
outside — no job, no result file, no complaint. That diagnosis used to go to
the BCM action output, which nothing read. The trace line for a successful
submission also records the `JOB_ENV` that went with it, because "what was this
run given" has to be answerable weeks later, when `SETTINGS` says whatever it
says then.

The module load matters at the top of the cycle too: a systemd --user service
has its own environment rather than a login shell's, and without the Slurm client
tools every check below reads as "node not in slurm" and the script exits
looking perfectly healthy. So a missing `sbatch` or `scontrol` is traced as an
`EXIT:` with the `PATH` it searched. Two, where it used to be four: `sinfo` and
`squeue` are not run on a node at all now, and requiring them would refuse to
cycle over tools nothing uses.

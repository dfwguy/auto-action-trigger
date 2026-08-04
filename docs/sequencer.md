# Benchmark sequencer (`actions/launch_job.sh`)

The active benchmark list is the `BENCHMARKS` variable in `SETTINGS` (or
`SETTINGS.default`, when a site has not made a `SETTINGS`). The commented
catalog above it lists every job in `jobs/$JOBS/` and which delivery
methodology calls for it — see [benchmarks.md](benchmarks.md) and
[settings.md](settings.md).

One job at a time, in listed order: the node submits the first benchmark that
has not passed and whose own last result is over an hour old, and submits
nothing more until that job is done. A job passes when every one of its runs
ends in `DONE`; anything else — `FAIL`, truncated output from a crashed node, or
no result at all — is offered again once its hour is up. There is no retry
limit: a node keeps being re-tested until it passes or an operator intervenes.
See [one job at a time](#one-job-at-a-time).

Benchmarks support multiple runs via `totalRuns=N` in the `.sbatch` file (see
`mnubergemm.sbatch`, which uses 12). Result files are named `<job>.txt` (single
run) or `<job>-run<N>.txt` (multiple runs). Prior failures are archived as
`<job>.fail<N>.txt` and left in place as the attempt history. A *passing*
result that `--all` re-runs is archived as `<job>.prev<N>.txt` instead — kept
the same way, but not counted as a rejected attempt by `status-check.sh`.

`totalRuns` is read out of the job file with `grep` — first line that mentions
it, everything right of the `=`, whitespace stripped — and never by sourcing it.
A job file is a script, and sourcing one here would run its body in the
sequencer's own shell, as root, on every node on every monitoring cycle. A value
that is not a positive integer falls back to `1` rather than to nothing, so a
typo costs coverage rather than the whole job.

A name in `BENCHMARKS` or `BURNIN` with no launcher behind it drops out of the
sweep entirely: it never goes pending, so it never blocks the node and never
surfaces as missing. That is the silent-nothing this tree exists to prevent, so
the survey traces `skip <job>: no <path>` for it, and `--all` re-queues from
what the survey found rather than from the configured list — a forced sweep
cannot pend a job that has nothing to submit.

## Host-launched jobs

Almost every job is a `.sbatch` the sequencer submits. A job whose tool does its
own submitting is a `.sh` the sequencer *runs on the node* instead, and
`llm-pretrain` is the only one — see [llmb.md](llmb.md) for why `llmb-run`
cannot be a batch payload.

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
  LLMB_INSTALL=... [<JOB_ENV>] bash <job>.sh
```

`SBATCH_JOB_NAME` is a real `sbatch` default, and it is also the name the
launcher is expected to put on its own submission — the queue gates on this node
match on it, so a job submitted under any other name is invisible to them.

There is no `SBATCH_OUTPUT` and no nodelist equivalent among the `SBATCH_*`
defaults, so pinning the job to this node and redirecting its output cannot be
handed over in the environment. They are the launcher's job, using whatever its
own tool provides; `llm-pretrain` does it with `llmb-run`'s `--nodelist` and
`--slurm-arg`. See
[llmb.md#pinning-the-submission](llmb.md#pinning-the-submission).

`LLMB_INSTALL` goes through the same allowlist as `JOB_ENV`, and for the same
reason: the submission is a string run by `su - $JOB_USER -c`, so an
unvalidated `SETTINGS` value would run as root on every node. See
[settings.md#what-is-rejected](settings.md#what-is-rejected).

Success is **not** taken from the launcher's exit status. A tool can exit `0`
having submitted nothing, and one that passes its own `--job-name` overrides
`SBATCH_JOB_NAME` and leaves a job every gate on the node reads as somebody
else's. So after running a `.sh` the sequencer asks `squeue` whether a job under
the expected name appeared, and traces `SUBMIT FAILED` with the launcher's exit
status and output when it did not.

A run is skipped at submit time when `verdict()` returns `DONE` for its result
file. What makes that skip safe is that the verdict is derived from the log on
every sweep and never read from a marker the job wrote at run time. When each
sbatch judged itself and wrote `DONE`, the skip froze that judgement: the fix
for the `-nonvlink` jobs running over TCP was correct, deployed, and
structurally unable to re-examine a single one of the results it was written
for. See [benchmarks.md](benchmarks.md#where-a-pass-is-decided).

A job counts as *attempted* when any of its archives exist, not only when a
current result file does — either suffix, since a `.prev<N>` is a pass moved
aside and is even less untested than a `.fail<N>`. A job mid-retry with its
output rotated away is tested, and reading it as untested would hold the
swept-clean condition on the drain below open indefinitely on exactly the node
that keeps failing.

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

## Two lists

`BENCHMARKS` is the sweep and always runs. `BURNIN` runs when `RUN_BURNIN` is
on. Both are surveyed every cycle, and both submit under their own job name —
`bringup-<node>` and `burnin-<node>`.

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
is archived, requeued or drained on until the marker clears.

With `RUN_BURNIN=no` — the default — nothing burns in, and `BURNIN` jobs appear
in `quick-view.txt` as `BURN-IN OFF` so a burn-in that never ran cannot be
misread as one that passed. See [settings.md](settings.md#burn-in).

## Running it by hand

BCM passes no arguments, so everything below is only ever an operator's.

| Flag | Effect |
|------|--------|
| `--explain`, `-n` | Dry run. Prints every gate and the `sbatch` commands it would issue; submits, drains, resumes and archives nothing. Safe while the trigger is live |
| `--force`, `-f` | Ignore the hourly gate and sweep now. Queues exactly what the next open cycle would have queued: everything without a passing result |
| `--all`, `-a` | Also re-queue jobs that *are* passing, sweeping the node from scratch. Implies `--force` |
| `--test JOB`, `-t` | Run `JOB` instead of the configured lists, whether or not `BENCHMARKS` names it. Repeatable. Implies `--force` and `--all`. See [below](#running-a-job-that-is-not-in-the-list) |
| `--verbose`, `-v` / `--quiet`, `-q` | Mirror the trace to stdout, or don't. Verbose by default when stdout is a terminal, quiet when it is not — so a hand-run says what it decided and BCM's action output stays empty |

Every decision the script makes is about `$HOSTNAME`, because the trigger fires
on the node it is deciding about. There is no node argument: sweeping a set of
nodes is a `pdsh`, and `-v` is worth adding there because stdout across `pdsh`
is a pipe rather than a terminal, so the trace would otherwise only reach each
node's own log.

```bash
pdsh -w 'ink50-dh01-h02-[11,13-18],ink50-dh01-h04-[11-13]' \
     '/home/cmods/bringup/actions/launch_job.sh -f -v'
```

Anything the script does not recognise — a node list included — is refused with
`exit 2` and nothing is swept. Run on the head node with no arguments it reports
`not known to slurm` and stops, which is correct and is now said on stdout
rather than only in a log under `results/<head node>/`.

Run it as `root` or as `JOB_USER` (`cmods`). Root becomes `JOB_USER` with
`su -`, and `JOB_USER` submits directly — `su` would ask itself for a password,
and over `pdsh` there is no terminal to ask on. As anyone else, the submission
is refused with that reason rather than attempted.

`--force` opens the hourly retry gate and nothing else. Every check that
decides whether the node should be given work at all is asked the same way as
on a normal cycle, and each one traces that `--force` did not override it:

- **`PAUSE_JOBS=yes`** — nothing is submitted. It is a site switch, not a
  timing gate; set it back to `no` to sweep.
- **`NODE_FILTER` not matching this node** — nothing is submitted. Also a site
  switch, and the one most likely to be forced over by accident: `-f` is
  normally issued across a whole rack over `pdsh`, which must not quietly test
  nodes the site took out. `--test` opens it; `--force` does not. See
  [settings.md](settings.md#restricting-which-nodes-run-jobs).
- **Another user's job on the node** — the node is left to them. Read from
  `scontrol listjobs`, so this costs the controller nothing.
- **A job of ours already out** — whether the in-flight marker says so, or the
  [submission guard](#the-guard-before-a-submission) finds one queued with no
  marker. Forcing on top of one is how a node ends up running the same
  benchmark twice; the trace names the `scancel` to run first if that is really
  what is wanted.

A drain is *not* among them any more, in either direction: with one job at a
time there is no batch to dump on a node the moment it is resumed, so a job
submitted to a drained node simply pends. See
[what the node can answer by itself](#what-the-node-can-answer-by-itself).

`--all` does not turn burn-in on: with `RUN_BURNIN=no` the `BURNIN` list is not
surveyed and not queued. It also does not invent or clear failures — the drain
decision still comes from what the results on disk say — and the jobs it
re-queues appear in `quick-view.txt` as `QUEUED  <- re-queued by --all`, so a
job being re-run with nothing wrong with it says so.

Combine either with `--explain` to see the batch before committing to it:

```bash
pdsh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --all --explain'
```

## Running a job that is not in the list

`jobs/<platform>/` carries more `.sbatch` files than `BENCHMARKS` names, and
`parsers/<platform>/verdict.sh` has gates for several of them. `--test` runs one
without editing `SETTINGS`, which is the point: a site's benchmark list is what
the fleet is judged on, and adding a job to it to try it once changes what every
node is expected to pass and what the daily report calls a hole.

```bash
pdsh -w ink50-dh01-h02-11 '/home/cmods/bringup/actions/launch_job.sh -t ethr -v'
```

The name must have a launcher behind it in `JOBS_DIR` — an `.sbatch`, or a `.sh`
carrying `job_launch=host` — or the run is refused with `exit 2` and the list of
names that do — unlike a bad `BENCHMARKS` entry,
which is traced and skipped. The operator is standing there, and a typo that
swept nothing would otherwise be indistinguishable from a healthy idle cycle.

`--test` **replaces** the lists rather than adding to them: `BENCHMARKS` is not
surveyed and `BURNIN` is not surveyed even with `RUN_BURNIN=yes`, so a run asked
for one job submits one job. It implies `--all` as well as `--force`, because a
job being run deliberately should run whether or not it passed last time.

Three things behave differently from an ordinary sweep, and each says so in the
trace:

- **Nothing drains.** A job the fleet is not judged on must not be able to take
  a node out of service, however it fails.
- **`quick-view.txt` is left alone.** It describes the `BENCHMARKS` and `BURNIN`
  columns, which this run has not surveyed; rewriting it would report every real
  column as `QUEUED`.
- **Most gates that decide whether the node should get work at all still
  apply** — `PAUSE_JOBS`, another user's job, and a job of ours already out.
  `--test` is a choice of *what* to submit, and those are about *whether* to.
  The exception is `NODE_FILTER`, which `--test` opens: naming a job and running
  the command on a particular node is already a deliberate statement about that
  node, and refusing would mean widening the site's filter to check one suspect
  machine. The trace says the node is outside the swept set, so a result the
  reports do not cover is explained where it happened.

The batch is submitted under the ordinary `bringup-<node>` job name, so a test
in flight is counted, cancelled and waited on exactly like any other benchmark,
and the next BCM cycle does not submit on top of it.

The result lands at `results/<node>/<job>.txt` like any other, which is what
lets `status-check.sh -t <job>` and `verdict.sh` judge it. Two consequences:

- The hourly retry gate reads the newest result file's mtime across the whole
  directory, so a manual test postpones the node's next ordinary sweep by up to
  `RETRY_INTERVAL_HOURS`. This is accepted rather than special-cased — a sweep
  deferred by an hour is visible in the trace, and teaching the cadence to
  ignore some result files is a subtler thing to get wrong.
- A result for a job outside `BENCHMARKS` has no column in the reports, so it is
  read with `status-check.sh -t` or by opening the file. It can also show up as
  the "live" column for a running node in `status-check.sh`, which picks the
  newest result file in the directory and does not know the job was ad-hoc.

## Retry and drain behaviour

The script fires on every BCM monitoring cycle, so the hourly cadence needs no
cron and no second trigger — just a time gate. Retry state is derived entirely
from files already on disk: the newest result file's mtime is when the last
sweep ran, and the archived `.fail<N>.txt` files are the attempt history. There
is no state file to keep in sync.

### One job at a time

A node has at most one job of ours out at any moment, and the record of it is a
local file — `results/<node>/.in-flight`, tab separated: job id, job name, run
number, total runs, submit epoch.

That file exists so the question "has this node got work out" can be answered
without asking slurmctld. It used to be answered with `squeue -n bringup-<node>`
and `squeue -n burnin-<node>`, every node, every monitoring cycle. BCM fires the
trigger about once a minute, so across 200 nodes that is on the order of a
thousand client invocations a minute — and `squeue -n <name>` pulls the **whole**
job table from slurmctld and filters it client-side, so the cost climbs with
both the fleet and the queue depth. Submitting one job instead of eight cuts the
depth as well: a fleet mid-sweep holds ~200 pending jobs where it used to hold
~1,600, which makes every remaining query cheaper for everyone on the cluster,
not just for this trigger.

Each cycle reads the marker and takes one of four branches. Only the last costs
a query:

| Marker | Job running here | Result file | What happens | Controller |
|---|---|---|---|---|
| absent | — | — | pick the next eligible job and submit it | 3 |
| present | yes | — | leave it alone | **0** |
| present | no | ends in a marker | job finished; clear and advance next cycle | **0** |
| present | no | no end marker, inside its window | not started yet; wait | **0** |
| present | no | no end marker, past its window | [stale](#when-a-marker-goes-stale) | 1 |

"Job running here" is `scontrol listjobs`, which contacts the local slurmstepd
processes and not slurmctld — see [what the node can answer by
itself](#what-the-node-can-answer-by-itself). An inconclusive answer reads as
**still running**, never as gone: only the stale branch below may conclude a job
has ended, and it asks the controller outright.

The result file is not evidence on its own. `sbatch --output` creates it when
the job *starts*, so its existence says nothing; what says the job ended is an
end marker in it, which is the same thing `verdict.sh` reads.

### What the node can answer by itself

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
drained, and no local command reports it. So it is fetched lazily, cached for
the cycle, and only by the paths that actually need it: issuing a drain,
clearing our own, and recovery. A healthy cycle never asks. When it is asked, it
is `scontrol show node <node>` rather than `sinfo -n <node>`: a single-node RPC
against a whole-table fetch filtered client-side.

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
| advancing to the next job | 3 — `scontrol show node`, the [submission guard](#the-guard-before-a-submission), `sbatch` |
| marker gone stale | 1 — `squeue -j`, plus recovery if it fires |

### Getting the job id right

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

### The guard before a submission

The marker says whether a job is out, and the marker is a file. A file can be
absent while a job is not: a cycle killed between `sbatch` returning and the
marker being written leaves one, and so does a marker deleted by hand. At that
moment the job is `PENDING` — invisible to `scontrol listjobs`, which sees only
what is running — so the node looks idle and would submit a second copy.

So immediately before submitting, and only then, one query asks what the
controller is holding under our two job names. Anything at all means something
of ours is already out, and nothing is submitted: the orphan is untracked, so it
is left to finish rather than cancelled, and the trace names it and the `scancel`
that would clear it.

It returns one column and both names in one call. Worth being precise about what
that buys: `-o '%i'` narrows what `squeue` **prints**, not what it fetches, and
`-n` filtering is not established to happen controller-side. What is genuinely
controlled is the number of invocations, which is why the two names go in one
call and why the host-launched path reuses the cached answer for its
[before-and-after id snapshot](#getting-the-job-id-right) rather than asking
again. SchedMD's own guidance is to limit `squeue` calls to the minimum
necessary, not to filter them harder.

The default state filter is pending and running, which is exactly the question
being asked, so no `-t` is passed.

This is the third call on an advance cycle, after `scontrol show node` and
before `sbatch` — and it is per job, not per monitoring cycle. A node with a job
running still costs nothing.

### When the controller does not answer

A saturated slurmctld does not return an error; it returns **nothing**. `sinfo`
exits 0 with empty output, `scontrol show node` prints nothing, and `sbatch`
fails with `Socket timed out on send/recv operation`. This is observed, not
hypothetical — a fleet of ~2,000 nodes each asking five times a minute produced
981 nodes concluding `not known to slurm (sinfo -N -n returned nothing)` in a
day, which is a node deciding it had been removed from the cluster because the
controller was busy.

The rule is that **no answer is never treated as an answer**. Every query that
can come back empty has a caller that fails closed:

- **The node state behind a drain.** If `scontrol show node` returns nothing,
  `drain_node` refuses and traces why. Draining on an unknown state takes a node
  out on no information, and overwrites whatever reason an operator put there
  with ours.
- **The local running check.** An inconclusive `scontrol listjobs` reads as
  *still running*, never as gone — see [one job at a time](#one-job-at-a-time).
- **The stale branch.** `squeue -j` returning nothing is the one case where
  empty *is* the answer, which is why that branch is only reached after the
  job's own walltime plus `INFLIGHT_GRACE_MINUTES` have passed, rather than on
  the first cycle a job is not seen.

`NODE_ASKED` separates "not fetched yet" from "fetched and got nothing", so a
run that hit a timeout does not ask again on every subsequent call.

This is a large part of why the call count matters at all. The load and the
wrong answers are the same problem: the queries that saturate the controller are
the queries that then come back empty and get believed.

### Cadence is per job, not per node

A job is eligible when it has not passed and its own result file is missing or
older than `RETRY_INTERVAL_HOURS`. There is no node-wide gate any more.

This is what lets one-at-a-time stay fast. Eight different benchmarks are each
eligible the moment the node is free, so the sweep advances as quickly as jobs
finish — one BCM cycle of idle between them, not one hour. Meanwhile no single
job can re-run inside the hour, which is the property the node-wide gate existed
to provide. A node failing everything still submits eight jobs an hour, exactly
as before.

Order comes from `BENCHMARKS` itself: the first eligible name in the list is the
one submitted. `BURNIN` is considered only when nothing in `BENCHMARKS` is
eligible. `#SBATCH --nice` no longer orders our own jobs against each other —
there is only ever one — and now matters only against work submitted by hand or
by other users. See [benchmarks.md](benchmarks.md#queue-priority).

### When a marker goes stale

A marker whose job is neither running here nor finished is either queued behind
somebody else's work, held, cancelled, or gone with the node under it. Locally
those are indistinguishable — all you see is a marker getting older — and
guessing wrong is expensive in both directions: resubmit too eagerly and the
node runs two copies of a job whose result is meant to judge the hardware; wait
forever and the node is silently idle, which is the failure this whole tree is
built to prevent.

So the wait is bounded by the job's own `#SBATCH -t` plus
`INFLIGHT_GRACE_MINUTES` (default 30). One fixed window could not serve both
`dcgmi-r1` at 25 minutes and `mnubergemm` at six hours a run.

Past that bound, and only then, one `squeue -j <id>` settles it:

- **Still pending, held after a failed launch** — cancelled, and the next cycle
  resubmits. A held job sits at priority 0 and never starts, so waiting on it
  waits forever.
- **Still pending otherwise** — left alone, and the trace names the reason and
  the `scancel` that would give up on it. Queued behind a long foreign job is a
  legitimate state, not a fault.
- **Not in the queue** — gone without finishing. The partial result is archived
  as `.fail<N>.txt` so the slot is free and the attempt is still on disk.

`MAX_JOB_HOURS` is checked against the marker rather than against `squeue`: a
job still running here past that limit drains the node, which is the one branch
that reads on past the in-flight gate, because a drain needs the node state.

The node is drained **only after a full sweep** — every benchmark has run at
least once and something is still not passing. A single failure mid-sweep does
not drain, so the rest of the sweep still runs and one bad test does not hide
the state of the others.

Drains fire only on failures that **just happened** — results newer than
`DRAIN_WINDOW_MINUTES` (default: 15). Stale result files never trigger a drain,
so a node you resume by hand is not immediately pulled back out of service; it
takes a fresh retry sweep failing again. Keep that window above the BCM
monitoring interval, or the drain is missed, and well below
`RETRY_INTERVAL_HOURS`.

The drain reason carries an `auto-retry` marker, and only drains carrying that
marker are ever cleared. A node drained by an operator is never auto-resumed,
and nothing is queued behind their drain — otherwise the whole batch would land
the moment they resumed it.

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
this have done" for a site running with drains off. See
[settings.md](settings.md#drains).

```
sweep runs → all pass            → burn-in if RUN_BURNIN, else idle + all DONE
sweep runs → some fail           → drain "<jobs> FAIL (auto-retry)"
             +1 hour             → resume, archive failures, re-queue them
             fails again         → drain again, repeat indefinitely
```

If a job has been running longer than `MAX_JOB_HOURS` (default: 7, sized to
clear `mnubergemm`'s 6:30:00 step — see
[settings.md](settings.md#retry-and-drain-policy)), the node is
drained with a timeout reason. That reason carries no marker, so a stuck job
stops the retry loop and waits for a human. Only a `RUNNING` job is measured
against that limit — a batch queued behind a dead node reads `0:00` for as long
as it waits, and draining the node for "timeout" would only bury the real
reason it is unusable.

A list queues nothing while anything from *that list* is already in the queue
for the node, pending included. The check asks `squeue` three ways: once per
job name (`-n bringup-<node>` and `-n burnin-<node>`, which catch our own
batches), and once by node (`-w`, which catches another user's job occupying
it — anything there carrying neither of our names is theirs, and the sequencer
leaves the node to them).

The name queries are the ones that matter when a node is down. Slurm does not
assign a node to a pending job, so a batch submitted with `-w` against an
unavailable node is invisible to the node query, and the sweep used to read
that as an idle node and submit the whole list again every hour.

Per list rather than one gate for both, because burn-in is queued alongside the
sweep now: a single "is anything of ours out there" check would let a three-day
burn-in block every benchmark retry behind it, and the nice values would never
get a chance to matter.

### Drains Slurm set itself

Before any of the gates above look at the node state, a drain that is Slurm
talking to itself — a failed prolog, a rogue process left by the previous job,
an empty reason — is cleared and the state re-read, so the rest of the cycle
runs against a node that is back in service. Without it every gate below reads
such a node as unusable and stops, correctly and permanently, since nothing
here ever cleared a drain it did not set.

The sequencer accepts only the `machine` class. A health-check drain belongs to
`node_health.sh`, which is the only thing that knows whether the check passes
now; the framework's own `auto-retry` drain is cleared by the sweep when the
benchmarks pass; an operator's drain belongs to the operator. The classification,
the three discriminators that protect an operator drain, the readiness checks
and the rate limit are in
[settings.md](settings.md#recovering-drains-slurm-set-itself); the argument for
each is in the header of `slurm-recovery.sh`.

The recovery runs **above** the `PAUSE_JOBS` gate and answers to `PAUSE_RECOVERY`
instead: putting a node back is not putting work on it, and the two are separate
decisions. See [settings.md](settings.md#pause-switches). Under `--explain` it
classifies and reports and issues nothing.

### Jobs the scheduler has given up on

A failed launch — slurmd not answering at the moment the scheduler tried to
start the job — does not fail the job. Slurm requeues it and *holds* it, and a
held job reads as `PENDING` to the name queries above while carrying priority 0:
it will never start, however healthy the node later becomes. Left alone, the
queue gate waits on it forever and the node idles, tracing `waiting on our own
queue` every cycle.

So a job of ours held with reason `launch failed requeued held` is cancelled and
left to the survey to re-queue. Cancelling is safe without any further check —
the queue was matched by name, so everything in it is `bringup-<node>` or
`burnin-<node>` by construction, and another user's job is never in that list.

Two bounds on it:

- **An operator's hold is never cancelled.** `JobHeldUser` and `JobHeldAdmin`
  are the same `PENDING`-at-priority-0, but a person chose it. Those are named
  in the trace and otherwise left alone.
- **One attempt per `RETRY_INTERVAL_HOURS`,** measured from the held job's own
  submit time — no counter on disk, and the replacement carries a fresh
  timestamp. The bound is load-bearing rather than tidy: the hourly gate keys
  off result mtime, and a job that never ran writes no result, so that gate
  stays open and would not slow a cancel/resubmit loop down at all. Without it
  a node that cannot launch anything would resubmit every monitoring cycle.

The scheduler's reason for any job of ours that is not cleanly schedulable is
appended to both the `queue:` line and the `EXIT: waiting on our own queue`
line. `waiting on our own queue` reads identically whether the job starts in a
minute or never starts at all, and the reason is the whole difference.

## What a submission carries

The submission is built as one string and handed to a shell as `JOB_USER`:
`su - $JOB_USER -c` when the cycle is root's, `bash -lc` when an operator is
already `cmods`. It loads the `slurm` module, makes `results/<node>` if it is
missing, and submits:

```
sbatch -w $HOSTNAME -J <bringup|burnin>-<node> \
       --export=ALL,RESULT_FILE=<file>[,<JOB_ENV>] --output=<file> <job>.sbatch
```

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
BCM's action output, which nothing reads. The trace line for a successful
submission also records the `JOB_ENV` that went with it, because "what was this
run given" has to be answerable weeks later, when `SETTINGS` says whatever it
says then.

The module load matters at the top of the cycle too: BCM runs the trigger with
its own environment rather than a login shell, and without the Slurm client
tools every check below reads as "node not in slurm" and the script exits
looking perfectly healthy. So a missing `sinfo`, `squeue`, `sbatch` or
`scontrol` is traced as an `EXIT:` with the `PATH` it searched.

## Every line the trace can write

`launch_job.sh` writes `results/<node>/trigger.log`, one timestamped line per
decision, and appends rather than truncates — it is the record, not a status
file. Reading it across the cluster is `trigger-log.sh` — see
[operations.md](operations.md#debugging-nothing-is-running); this is what the
lines mean.

Three conventions hold across all of them:

- **`EXIT:` is the last line of a cycle that stopped.** Every gate that can end
  the run names itself that way, so the newest `EXIT:` in a node's log is the
  reason nothing is happening. A cycle that ran to the end has no `EXIT:` line
  at all — it has `submitted` lines, or the survey and the gates it passed.
- **A forced run says so, and says what it did not open.** `--force` writes a
  `MANUAL:` line at the start, and every gate it does *not* override appends
  ` --force does not override that.` to its own line, where the operator is
  already looking.
- **A trace that cannot be written is spoken instead.** Writability is tested
  once per run; if `trigger.log` is not writable by whoever is running — the
  common case being an operator running as `cmods` against a log root's cycle
  created — the run turns verbose, says so on stderr with the `chown` to fix it,
  and mirrors everything to stdout. A run that can neither write nor speak is
  the one state this whole mechanism exists to make impossible.

The log is trimmed to its last 2000 lines when it passes 1 MB. It gets a line or
two per monitoring cycle, forever.

### Startup and housekeeping

| Line | When |
|------|------|
| `MANUAL: --force -- hourly gate bypassed[, --all -- passing jobs re-queued too]` | A human ran it. Without this, an hour of off-cadence results reads as the sequencer misbehaving |
| `MANUAL TEST: --test <jobs> -- BENCHMARKS and BURNIN not surveyed this run, no drains, quick-view.txt left alone` | A human ran an ad-hoc job. Replaces the `MANUAL:` line, and is what explains a result in a column the reports do not have — see [above](#running-a-job-that-is-not-in-the-list) |
| `chown <user> <path>` | `results/` or `results/<node>`, or `trigger.log` / `quick-view.txt`, handed back to `JOB_USER` — see [below](#result-path-ownership) |
| `WARNING: <dir> is owned by <user>, not <JOB_USER>, and we are not root` | The same problem seen from a hand-run, which can diagnose it but not fix it |
| `WARNING: JOB_ENV entry '<pair>' is not NAME=VALUE …  -- dropped` | A rejected `JOB_ENV` entry. The sweep still runs, and the reason it ran without your variable is written next to it — see [settings.md](settings.md#what-is-rejected) |
| `EXIT: <tool> not on PATH after 'module load slurm' (PATH=…)` | No Slurm client tools; every check below would have read as a healthy idle node |
| `EXIT: NODE_FILTER='<globs>' … does not match <node> -- no jobs submitted here` | This node is outside the set being tested — see [settings.md](settings.md#restricting-which-nodes-run-jobs). Written every cycle on purpose: "why is this node not testing" has to be answerable from the node's own trace. Names `--force` when it was passed, so the flag does not look ignored |
| `NODE_FILTER='<globs>' does not match <node>, but --test <jobs> names this node … -- testing anyway` | `--test` opens the filter where `--force` does not. Says the node is outside the swept set, so a result the reports do not cover is explained where it happened |
| `state=<node state> explain=<0\|1>` | The ordinary first line of a working cycle |

### Pause and recovery

| Line | When |
|------|------|
| `EXIT: PAUSE_JOBS=<value> in <settings file>` | Paused: nothing submitted, drained or archived. Drains Slurm set itself are cleared above this gate, under `PAUSE_RECOVERY` |
| `PAUSE_JOBS=<value> ... -- explaining anyway` | `--explain` reads through the pause; it writes nothing either way |
| `recovery paused: PAUSE_RECOVERY=<value>` | Drains left exactly where they are, whatever `RECOVER_SLURM_DRAINS` says |
| `PAUSE_JOBS: cancelled pending <ids>` | Pending jobs of ours cleared, so a pause reaches the queue and not just submission |
| `PAUSE_JOBS: job <id> still RUNNING for <t> -- left to finish` | A running job is not killed; the id is named so an operator can `scancel` it deliberately |
| `--force does not override PAUSE_JOBS: it is a site switch, not a timing gate.` | Appended when a forced run hits the pause |
| `RECOVER …` / `state after recovery=<state>` | A drain Slurm set itself was cleared and the node state re-read — see [above](#drains-slurm-set-itself) |
| `WARNING: <home>/slurm-recovery.sh is missing` | A deployment that predates the file. Named rather than skipped quietly, because its absence is invisible from outside: nodes simply stay drained |

### The queue

| Line | When |
|------|------|
| `EXIT: <node> not known to slurm (sinfo -N -n returned nothing)` | Usually a run on the head node |
| `EXIT: <n> job(s) not ours on <node> -- leaving the node to them` | Somebody else is using the node |
| `queue: bench=<n> burnin=<n> [running=<t>] [<id> <state> <reason>…]` | Every cycle that gets this far. The per-job detail is only rendered for jobs that are not cleanly schedulable, so a healthy cycle keeps this to one line |
| `job <id> held after a failed launch ('<reason>') <n>s ago -- cancelling and resubmitting in <n>s` | A held job seen before its retry interval is up |
| `CANCELLED <id> -- held <n>s after a failed launch` | Cleared; the survey below decides what to resubmit |
| `job <id> is held after a failed launch, but its submit time … did not parse -- left queued` | Cancel it by hand |
| `EXIT: waiting on our own queue [(RUNNING for <t>, limit <n>h)] [<detail>]` | The normal busy cycle. The scheduler's reason for a job that is not cleanly schedulable is appended — this line reads identically whether the job starts in a minute or never, and the reason is the whole difference |

### The survey

| Line | When |
|------|------|
| `EXIT: <parsers>/verdict.sh is missing …` | Four lines, with the reason spelled out: without the pass/fail rule nothing can be judged, and treating that as "no results yet" would requeue every benchmark on every node every hour |
| `skip <job>: no <path>` | A listed benchmark with no job file |
| `<job> run <n>: <STATUS> -- <reason> [<detail>]` | One per failing run, with why rather than just that. Suppressed while that list has jobs in the queue: `INCOMPLETE` logged once a cycle for six hours reads as a node failing when it is a node working |
| `survey[ (--test)]: pending=[…] failed=[…] swept=<0\|1> busy=<0\|1>` | The benchmark list's state, or the `--test` list's in place of it |
| `burn-in survey: …` | The same for `BURNIN`, when `RUN_BURNIN` is on |
| `RUN_BURNIN=<value> but BURNIN is empty -- nothing to burn in` | Burn-in switched on with no list behind it |
| `EXIT: every benchmark and every burn-in job passing` | The node is done |
| `EXIT: every benchmark passing (burn-in not run: RUN_BURNIN=<value>)` | The node is done as far as it is configured to go — which is not the same thing, and says which |
| `WARNING: could not write <quick-view> as <user>` | The trace above is then the only current state |

### Drain, resume and the gates before submitting

| Line | When |
|------|------|
| `DRAIN: <jobs> FAIL[: <reason>] (auto-retry)` | A full sweep has run and something failed inside `DRAIN_WINDOW_MINUTES` |
| `DRAIN: job timeout after <n>h (RUNNING)` | Past `MAX_JOB_HOURS`. No marker, so this one stops the retry loop and waits for a human |
| `drain skipped, already <state>: <reason>` | Somebody or something else got there first; the node is left alone |
| `drain suppressed by DRAIN_AFTER_FAILED_BENCHMARK=<value>: <reason>` | What the drain would have been, at a site running with drains off |
| `drain suppressed by --test: <reason>` | The same, on an ad-hoc run: a job the fleet is not judged on cannot take a node out |
| `RESUME: clearing own drain (<reason>)` | Our own `auto-retry` drain, and only ever that one |
| `EXIT: newest result is <n>s old, next sweep in <n>s` | The hourly gate, closed. The single most common line in the file |
| `hourly gate bypassed by --force (…would have waited <n>s)` | The hourly gate, forced |
| `hourly gate open (newest result age=<n>s, -1 means no results on disk)` | The hourly gate, open on its own |
| `EXIT: node is <state> for a reason that is not ours -- '<reason>' does not carry 'auto-retry'.` | An operator's drain. Names the `scontrol … state=RESUME` that releases it |
| `NOTE: JOB_ENV sets <name>, but <job>.sbatch exports its own` | The job file wins. Without the line, a `SETTINGS` entry that does nothing looks exactly like one that works |
| `WOULD SUBMIT <job> run <n>[ (existing <STATUS> result kept as .<fail\|prev><N>.txt)]: <command>` | `--explain` only |
| `submitted <job> run <n>: Submitted batch job <id> [(JOB_ENV: …)]` | Work went out |
| `SUBMIT FAILED <job> run <n>: <sbatch output>` | Work did not go out, and `sbatch` says why |

A new gate gets a line here and a line in the table above it. An `exit 0` with
no explanation is a bug even when the behaviour is correct: most cycles
legitimately have nothing to do, so a node that has silently stopped testing
looks exactly like a node that is quietly idle.

## Result-path ownership

Clearing `results/` is safe at any time:

```bash
mv results results.$(date +%F)     # or: rm -rf results
```

The sequencer runs as root on each node (BCM actions do), so root is what
recreates `results/` and `results/<node>` on the next monitoring cycle — but the
benchmarks are submitted as `cmods`, and `sbatch --output` writes as that user.
A root-owned result directory means `sbatch` returns a job id, Slurm schedules
the job, and it dies at startup with nowhere to write: the node returns to idle
with no result file, no `FAIL`, and no archive, which is indistinguishable from
never having been tested.

`launch_job.sh` therefore re-checks ownership of both directories on every cycle
and hands them back to `cmods`, so a cleared tree repairs itself. To fix an
existing tree immediately rather than waiting for a cycle:

```bash
chown -R cmods:cmods /home/cmods/bringup/results
```

## Slurm permissions

`scontrol update nodename=...` requires privilege. It works as `root`, as the
`SlurmUser` (typically `slurm`), or as an account with an admin level set in the
accounting database. To grant a user that access:

```bash
sacctmgr modify user name=<user> set adminlevel=Operator        # drain/resume nodes, manage jobs
sacctmgr modify user name=<user> set adminlevel=Administrator   # full control, incl. accounting
sacctmgr show user <user> withassoc format=User,AdminLevel      # verify
```

`Operator` is enough for node state changes and is the right level for anyone
doing bringup. `Administrator` additionally allows modifying accounts,
associations, and QOS — grant it sparingly.

The `sacctmgr modify` command itself must be run by `root`, the `SlurmUser`, or
an existing `Administrator`, and requires `slurmdbd` with accounting storage
configured. Without accounting enabled, admin levels do not apply and node state
changes are limited to `root` and the `SlurmUser`.

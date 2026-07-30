# Benchmark sequencer (`actions/launch_job.sh`)

The active benchmark list is the `BENCHMARKS` variable in `SETTINGS` (or
`SETTINGS.default`, when a site has not made a `SETTINGS`). The commented
catalog above it lists every job in `jobs/$JOBS/` and which delivery
methodology calls for it — see [benchmarks.md](benchmarks.md) and
[settings.md](settings.md).

Once an hour, every benchmark in that list without a passing result is queued in
listed order, and Slurm runs them back to back on the node. A job passes when
every one of its runs ends in `DONE`; anything else — `FAIL`, truncated output
from a crashed node, or no result at all — is queued again on the next sweep.
There is no retry limit: a node keeps being re-tested until it passes or an
operator intervenes.

Benchmarks support multiple runs via `totalRuns=N` in the `.sbatch` file (see
`mnubergemm.sbatch`, which uses 12). Result files are named `<job>.txt` (single
run) or `<job>-run<N>.txt` (multiple runs). Prior failures are archived as
`<job>.fail<N>.txt` and left in place as the attempt history. A *passing*
result that `--all` re-runs is archived as `<job>.prev<N>.txt` instead — kept
the same way, but not counted as a rejected attempt by `status-check.sh`.

`totalRuns` is read out of the job file with `grep` — first line that mentions
it, everything right of the `=`, whitespace stripped — and never by sourcing it.
A `.sbatch` is a job script, and sourcing one here would run its body in the
sequencer's own shell, as root, on every node on every monitoring cycle. A value
that is not a positive integer falls back to `1` rather than to nothing, so a
typo costs coverage rather than the whole job.

A name in `BENCHMARKS` or `BURNIN` with no `$JOBS_DIR/<name>.sbatch` behind it
drops out of the sweep entirely: it never goes pending, so it never blocks the
node and never surfaces as missing. That is the silent-nothing this tree exists
to prevent, so the survey traces `skip <job>: no <path>` for it, and `--all`
re-queues from what the survey found rather than from the configured list — a
forced sweep cannot pend a job that has nothing to submit.

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

What serializes the batch is `#SBATCH --exclusive` in every `jobs/*.sbatch`.
Without serialization the whole batch is eligible at once and a GPU job landing
on top of dcgmi's stress plugins fails on buffer allocation. Ordering follows the
`BENCHMARKS` list in practice — the jobs are submitted in that order, carry
equal priority, and a whole-node job leaves no backfill window for a later one
to slip into — but that is a scheduling consequence, not a guarantee. No job
should depend on an earlier one having finished.

This used to be `--dependency=singleton` over a shared job name. Singleton
matches on name alone, cluster-wide, so the name had to carry the hostname or a
bare `bringup` would have serialized every node in the rack against every other:
serialization by string equality, and silent about what a job would actually be
given once it ran. `--exclusive` states the real requirement — this job wants
the whole node — and additionally keeps *other people's* jobs off the node
mid-benchmark, which singleton never did.

The shared job name `bringup-<node>` stays, for a different reason: `squeue -n
bringup-<node>` is how the sequencer sees its own jobs while they are still
queued and unplaced, which `squeue -w <node>` cannot show.

## Two lists

`BENCHMARKS` is the sweep and always runs. `BURNIN` runs when `RUN_BURNIN` is
on. Both are surveyed every cycle and both can be in the queue at the same
time, each under its own job name — `bringup-<node>` and `burnin-<node>`.

Those names are what make the two independent. "Is anything of ours already
queued" is the question that stops the sequencer piling up duplicate
submissions, and with two lists it has to be asked per list: otherwise a
burn-in sitting in the queue for three days would block every benchmark retry
behind it.

Ordering between them is Slurm priority — `#SBATCH --nice` in each job file,
`0` for the dcgmi gates, `20` for the rest of the sweep, `100000` for burn-in.
See [benchmarks.md](benchmarks.md#queue-priority). Priority reorders what has
not started; it does not preempt what has, because every job is `--exclusive`.
So a benchmark queued during a burn-in waits out the run on the node (up to
`MAX_JOB_HOURS`) and then goes ahead of the eleven still waiting.

Burn-in used to be gated behind a clean sweep instead, which made the ordering
absolute at the cost of making it rigid: a node failing one benchmark could
never start burning in, and a node three days into a burn-in could not pick up a
benchmark retry until it finished. Priority buys back both at the cost of the
one thing it cannot do — a site that needs a benchmark to interrupt a *running*
burn-in needs Slurm preemption (`PreemptType`/`PreemptMode`, with the two lists
in different partitions or QOSes), which is scheduler configuration and not
something this script can arrange.

A list with jobs in the queue is not judged that cycle: its result files are
being written right now, and a file with no end marker is a job in progress
rather than one that died. Nothing from such a list is archived, requeued, or
drained on until its queue is empty.

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
- **A drained, down or maintenance node** — nothing is submitted, and nothing
  is added to `squeue` on its behalf, unless the drain is one of ours (it
  carries `DRAIN_MARKER`), which is the ordinary retry loop. An operator's
  drain still has to be released by an operator.
- **Another user's job on the node** — the node is left to them.
- **Our own batch already queued** — skipped, per list. Forcing on top of a
  queued batch is how a node ends up running the same benchmark twice; the
  trace names the `scancel -n bringup-<node>` / `-n burnin-<node>` to run first
  if that is really what is wanted.

`--all` does not turn burn-in on: with `RUN_BURNIN=no` the `BURNIN` list is not
surveyed and not queued. It also does not invent or clear failures — the drain
decision still comes from what the results on disk say — and the jobs it
re-queues appear in `quick-view.txt` as `QUEUED  <- re-queued by --all`, so a
job being re-run with nothing wrong with it says so.

Combine either with `--explain` to see the batch before committing to it:

```bash
pdsh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --all --explain'
```

## Retry and drain behaviour

The script fires on every BCM monitoring cycle, so the hourly cadence needs no
cron and no second trigger — just a time gate. Retry state is derived entirely
from files already on disk: the newest result file's mtime is when the last
sweep ran, and the archived `.fail<N>.txt` files are the attempt history. There
is no state file to keep in sync.

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

The recovery runs **after** the `PAUSE_JOBS` gate: a pause means this script
touches Slurm in neither direction, and a resume is touching Slurm. Under
`--explain` it classifies and reports and issues nothing.

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
| `chown <user> <path>` | `results/` or `results/<node>`, or `trigger.log` / `quick-view.txt`, handed back to `JOB_USER` — see [below](#result-path-ownership) |
| `WARNING: <dir> is owned by <user>, not <JOB_USER>, and we are not root` | The same problem seen from a hand-run, which can diagnose it but not fix it |
| `WARNING: JOB_ENV entry '<pair>' is not NAME=VALUE …  -- dropped` | A rejected `JOB_ENV` entry. The sweep still runs, and the reason it ran without your variable is written next to it — see [settings.md](settings.md#what-is-rejected) |
| `EXIT: <tool> not on PATH after 'module load slurm' (PATH=…)` | No Slurm client tools; every check below would have read as a healthy idle node |
| `state=<node state> explain=<0\|1>` | The ordinary first line of a working cycle |

### Pause and recovery

| Line | When |
|------|------|
| `EXIT: PAUSE_JOBS=<value> in <settings file>` | Paused: nothing submitted, drained, resumed or archived |
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
| `survey: pending=[…] failed=[…] swept=<0\|1> busy=<0\|1>` | The benchmark list's state |
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

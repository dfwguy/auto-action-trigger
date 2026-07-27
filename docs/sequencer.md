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

What serializes the batch is `#SBATCH --exclusive` in every `jobs/*.sbatch`.
Without serialization the whole batch is eligible at once and a GPU job landing
on top of dcgm's stress plugins fails on buffer allocation. Ordering follows the
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
`0` for the dcgm gates, `20` for the rest of the sweep, `100000` for burn-in.
See [benchmarks.md](benchmarks.md#queue-priority). Priority reorders what has
not started; it does not preempt what has, because every job is `--exclusive`.
So a benchmark queued during a burn-in waits out the run on the node (up to
`MAX_JOB_HOURS`) and then goes ahead of the eleven still waiting.

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
| `<nodes>` | A pdsh node list. The script re-runs itself on each of those nodes instead of acting where it was typed |

Every decision the script makes is about `$HOSTNAME`, because the trigger fires
on the node it is deciding about. A node list is therefore not something it can
act on where you typed it — it fans out over `pdsh` and each node decides for
itself:

```bash
# from the head node, both equivalent
./actions/launch_job.sh -f 'ink50-dh01-h02-[11,13-18],ink50-dh01-h04-[11-13]'
pdsh -w 'ink50-dh01-h02-[11,13-18]' '/home/cmods/bringup/actions/launch_job.sh -f -v'

# on the node itself
./actions/launch_job.sh -f
```

Run it as `root` or as `JOB_USER` (`cmods`). Root becomes `JOB_USER` with
`su -`, and `JOB_USER` submits directly — `su` would ask itself for a password,
and over `pdsh` there is no terminal to ask on. As anyone else, the submission
is refused with that reason rather than attempted.

Without a node list the script decides about the node it is on, so running it
on the head node reports `not known to slurm` and stops — which is correct, and
is now said on stdout rather than only in a log under `results/<head node>/`.

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

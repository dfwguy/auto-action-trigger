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
`<job>.fail<N>.txt` and left in place as the attempt history.

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
sweep runs → all pass            → node left idle, quick-view all DONE
sweep runs → some fail           → drain "<jobs> FAIL (auto-retry)"
             +1 hour             → resume, archive failures, re-queue them
             fails again         → drain again, repeat indefinitely
```

If a job has been running longer than `MAX_JOB_HOURS` (default: 13, sized to
clear `mnubergemm`'s 11:54:00 step — see
[settings.md](settings.md#retry-and-drain-policy)), the node is
drained with a timeout reason. That reason carries no marker, so a stuck job
stops the retry loop and waits for a human. Only a `RUNNING` job is measured
against that limit — a batch queued behind a dead node reads `0:00` for as long
as it waits, and draining the node for "timeout" would only bury the real
reason it is unusable.

A sweep queues nothing while anything of ours is already in the queue for the
node, pending included. The check asks `squeue` twice: once by node
(`-w`, which catches another user's job occupying it) and once by the shared
job name (`-n bringup-<node>`, which catches our own batch). The name query is
the one that matters when a node is down — Slurm does not assign a node to a
pending job, so a batch submitted with `-w` against an unavailable node is
invisible to the node query, and the sweep used to read that as an idle node
and submit the whole list again every hour.

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

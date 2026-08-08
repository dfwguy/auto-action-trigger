# Run a job by hand

BCM passes `actions/launch_job.sh` no arguments, so everything here is only ever
an operator's. Why each gate answers the way it does is in
[explanation/sequencing.md](../explanation/sequencing.md).

| Flag | Effect |
|------|--------|
| `--explain`, `-n` | Dry run. Prints every gate and the `sbatch` commands it would issue; submits, drains, resumes and archives nothing. Safe while the trigger is live |
| `--force`, `-f` | Ignore the hourly gate and sweep now. Queues exactly what the next open cycle would have queued: everything without a passing result |
| `--all`, `-a` | Also re-queue jobs that *are* passing, sweeping the node from scratch. Implies `--force` |
| `--test JOB`, `-t` | Run `JOB` instead of the configured lists, whether or not `BENCHMARKS` names it. Repeatable. Implies `--force` and `--all`. See [below](#running-a-job-that-is-not-in-the-list) |
| `--verbose`, `-v` / `--quiet`, `-q` | Mirror the trace to stdout, or don't. Verbose by default when stdout is a terminal, quiet when it is not |

## Sweeping a set of nodes

Every decision the script makes is about `$HOSTNAME`, because the trigger fires
on the node it is deciding about. There is no node argument: sweeping a set of
nodes is a `pdsh`, and `-v` is worth adding there because stdout across `pdsh`
is a pipe rather than a terminal, so the trace would otherwise only reach each
node's own log.

```bash
pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18],ink50-dh01-h04-[11-13]' \
     '/home/cmods/bringup/actions/launch_job.sh -f -v'
```

Every command in these docs that reaches a node goes through `pdsh`, never a
bare `ssh`, so the same line works unchanged whether `-w` names one node or a
whole rack — see
[explanation/architecture.md#reaching-nodes-is-pdsh-not-ssh](../explanation/architecture.md#reaching-nodes-is-pdsh-not-ssh)
for why `-R ssh` is always spelled out.

Anything the script does not recognise — a node list included — is refused with
`exit 2` and nothing is swept. Run on the head node it stops before any of it,
saying the host is not a compute node — see
[explanation/sequencing.md#a-host-that-is-not-a-compute-node](../explanation/sequencing.md#a-host-that-is-not-a-compute-node).

Run it as `root` or as `JOB_USER` (`cmods`). Root becomes `JOB_USER` with
`su -`, and `JOB_USER` submits directly — `su` would ask itself for a password,
and over `pdsh` there is no terminal to ask on. As anyone else, the submission
is refused with that reason rather than attempted.

## What `--force` does not open

`--force` opens the hourly retry gate and nothing else. Every check that decides
whether the node should be given work at all is asked the same way as on a
normal cycle, and each one traces that `--force` did not override it:

- **`PAUSE_JOBS=yes`** — nothing is submitted. Set it back to `no` to sweep.
- **`NODE_FILTER` not matching this node** — nothing is submitted. `--test`
  opens it; `--force` does not.
- **Another user's job on the node** — the node is left to them.
- **A job of ours already out** — forcing on top of one is how a node ends up
  running the same benchmark twice; the trace names the `scancel` to run first
  if that is really what is wanted.

A drain is *not* among them, in either direction: a job submitted to a drained
node simply pends.

`--all` does not turn burn-in on: with `RUN_BURNIN=no` the `BURNIN` list is not
surveyed and not queued. It also does not invent or clear failures — the drain
decision still comes from what the results on disk say — and the jobs it
re-queues appear in `quick-view.txt` as `QUEUED  <- re-queued by --all`.

Combine either with `--explain` to see the batch before committing to it:

```bash
pdsh -R ssh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --all --explain'
```

## Running a job that is not in the list

`jobs/$JOBS/` carries more `.sbatch` files than `BENCHMARKS` names, and
`parsers/$PARSERS/verdict.sh` has gates for several of them. `--test` runs one
without editing `SETTINGS`, which is the point: a site's benchmark list is what
the fleet is judged on, and adding a job to it to try it once changes what every
node is expected to pass and what the daily report calls a hole.

```bash
pdsh -R ssh -w ink50-dh01-h02-11 '/home/cmods/bringup/actions/launch_job.sh -t ethr -v'
```

The name must have a launcher behind it in `JOBS_DIR` — an `.sbatch`, or a `.sh`
carrying `job_launch=host` — or the run is refused with `exit 2` and the list of
names that do. Unlike a bad `BENCHMARKS` entry, which is traced and skipped: the
operator is standing there, and a typo that swept nothing would otherwise be
indistinguishable from a healthy idle cycle.

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
  The exception is `NODE_FILTER`, which `--test` opens.

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

`--test` is the supported way to run one job, and it is what you want almost
always: it supplies the site's paths, the result path and the job name, none of
which a job file can work out for itself. Calling `sbatch` on one of these files
yourself is
[submit-a-job-file-directly.md](submit-a-job-file-directly.md) — reach for it
only when you need to change something `--test` does not expose.

## Re-running health checks by hand

The health side has the same shape: `actions/node_health.sh` decides about the
node it runs on and takes no node argument, so a sweep is `pdsh` over the nodes.

```bash
pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18]' '/home/cmods/bringup/actions/node_health.sh -f -v'
```

| Flag | Does |
|---|---|
| `--explain`, `-n` | print every gate, run no check, drain nothing |
| `--force`, `-f` | ignore the cadence gate and run the checks now |
| `--verbose`, `-v` | mirror the trace to stdout — the default on a tty, off under BCM and `pdsh` |
| `--quiet`, `-q` | never mirror it |

`--force` opens the cadence gate and nothing else. `PAUSE_HEALTH_CHECKS`, the
not-a-compute-node gate and the baseline-is-this-node refusal all still apply,
for the same reason `--force` does not open `PAUSE_JOBS` above: they are site
switches and safety gates, not timing.

From the head node, and where you do not want to wait for a monitoring cycle to
reach the node, ask for the re-check instead of running it:

```bash
bash health-check.sh --refresh 'ink50-dh01-h02-[11,13-18]'
bash health-check.sh --explain ink50-dh01-h02      # when is each node next due
```

That sets the `refresh` sentinel, which the next cycle on each node consumes
ahead of its cadence. It needs write access to `logs/<node>/`, not root on the
node. See
[explanation/health-cadence.md](../explanation/health-cadence.md).

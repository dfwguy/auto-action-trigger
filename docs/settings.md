# Settings (`SETTINGS`, `SETTINGS.default`)

Everything configurable lives in one file at the bringup root. Two files,
strictly:

| File | What it is |
|------|------------|
| `SETTINGS.default` | Ships with the framework. Tracked in git, replaced by every tarball drop. |
| `SETTINGS` | The site's own copy. Git-ignored, never written by an upgrade. |

`settings.sh` reads `SETTINGS` if it exists, and `SETTINGS.default` if it does
not. They are not layered — a site's `SETTINGS` is the whole answer.

```bash
cp SETTINGS.default SETTINGS
```

What *is* layered is the defaults inside `settings.sh`: any key a settings file
leaves unset is filled in there. So a `SETTINGS` only has to carry the lines the
site actually changed, and a `SETTINGS` written against an older release does
not break when a new key is added — the variable gets its shipped value rather
than an empty string. That backfill is the reason this is safe to upgrade
through: without it, adding a key would leave every existing site with a path
built from an empty variable, and the failure surfaces as "no benchmarks found"
rather than as anything naming settings.

Editing `SETTINGS.default` in place works until the next tarball drop
overwrites it. Do it once and forget, and the site's configuration silently
reverts on an upgrade.

## Which set of things to run

Three settings each name a subdirectory:

| Setting | Directory | Contents |
|---------|-----------|----------|
| `JOBS` | `jobs/$JOBS/` | The `.sbatch` files `launch_job.sh` submits — see [benchmarks.md](benchmarks.md) |
| `HEALTHCHECKS` | `health-checks/$HEALTHCHECKS/` | One file per check, run by `node_health.sh` — see [health-checks.md](health-checks.md) |
| `PARSERS` | `parsers/$PARSERS/` | `verdict.sh`: the pass/fail rule and the bandwidth floors every result is judged against |

All three ship as `nvl72`. They are separate variables rather than one
`PLATFORM` because they do not have to move together: a site can run the nvl72
job set against a health-check set trimmed for its hardware, and a new platform
usually starts by reusing the existing parsers.

`settings.sh` exports `JOBS_DIR`, `HEALTHCHECKS_DIR` and `PARSERS_DIR` already
joined to the bringup root, so no script has to remember which variable indexes
which directory.

## The benchmark list

`BENCHMARKS` is the ordered list of jobs to run. Everything in it without a
passing result is queued once an hour, in listed order. A name with no
`jobs/$JOBS/<name>.sbatch` behind it is skipped with a line in the trace rather
than failing — so a job set that does not have every listed benchmark is not an
error, it just runs fewer of them.

The commented catalog above it in `SETTINGS.default` lists every available job
and which delivery methodology calls for it.

## Container images

`CONTAINERS` is the list `build_containers.sh` builds when no image is named on
the command line. It ships as `hpc-benchmarks`, which is what the default
`BENCHMARKS` list needs and nothing more; add an image here at the same time as
you add the job that uses it.

An explicitly empty `CONTAINERS=""` means "build nothing" and is left that way
— it is the one setting where empty is a real answer rather than an omission,
so `settings.sh` backfills it only when the key is absent altogether. See
[containers.md](containers.md#which-images-get-built).

## Drains

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # node_health.sh: mismatch against the baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # launch_job.sh: failed sweep, and MAX_JOB_HOURS
```

Both ship off. These replace the old `NODRAIN` file, which is gone; a `NODRAIN`
left over from an earlier deployment now does nothing.

Anything not affirmative reads as off — `yes`, `true`, `1` and `on` enable, and
everything else, including a typo and including empty, disables. For two
switches that decide whether nodes get taken out of service, an unreadable
value has to mean "don't".

The full operational picture — what changes when they are off, what does not,
and which one to turn on first — is in
[operations.md](operations.md#disabling-drains).

## Retry and drain policy

| Setting | Default | Meaning |
|---------|---------|---------|
| `RETRY_INTERVAL_HOURS` | `1` | Hours between sweeps, measured from the newest result file on the node |
| `MAX_JOB_HOURS` | `6` | A benchmark `RUNNING` longer than this drains the node |
| `DRAIN_WINDOW_MINUTES` | `15` | Only failures newer than this drain |
| `DRAIN_MARKER` | `auto-retry` | Written into every drain reason this framework issues; only drains carrying it are ever cleared automatically |

`DRAIN_WINDOW_MINUTES` has to sit above the BCM monitoring interval or the
drain is missed entirely, and well below `RETRY_INTERVAL_HOURS`. Its purpose is
that without it, `launch_job.sh` would re-drain from stale result files on every
monitoring cycle — a node an operator had just resumed would be pulled straight
back out of service.

`DRAIN_MARKER` is what makes an operator drain survive. `launch_job.sh` will not
queue work behind a drain that does not carry it, and will not clear one.

## Accounts and paths

| Setting | Default | Meaning |
|---------|---------|---------|
| `JOB_USER` | `cmods` | The account Slurm jobs are submitted as, and the owner `results/` and `logs/` are handed to |
| `BRINGUP_HOME` | `/home/cmods/bringup` | Where this checkout lives on the cluster |

`BRINGUP_HOME` is documentation for the BCM actions rather than something they
read: `node_health.sh` and `launch_job.sh` carry the path literally, because BCM
invokes them with no working directory to infer one from and they have to find
`settings.sh` before they can read anything from it. Deploying elsewhere means
editing `home=` at the top of both, and this setting to match. Every other
script resolves its own location and ignores it.

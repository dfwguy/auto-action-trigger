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

### Available single-node jobs (`jobs/nvl72/`)

Jobs are organized by AI Factory Testing Plan (SNT) tier:

| Job | Description | Tier |
|-----|-------------|------|
| `dcgm-r2` | TTM DCGM gate (`dcgmi diag -r 2`) | TTM |
| `dcgm` | Hybrid DCGM gate (`dcgmi diag -r 3`) | Hybrid |
| `dcgm-r4` | Exhaustive gate (`dcgmi diag -r 4`) | Exhaustive |
| `nvbandwidth` | HBM / PCIe / NVLink bandwidth | Hybrid / Exhaustive |
| `allreduce` `alltoall` | NCCL single-node, NVLink scope | Hybrid / Exhaustive |
| `allreduce-nonvlink` `alltoall-nonvlink` | NCCL single-node, no NVLink (HCA loopback) | Hybrid / Exhaustive |
| `nvsm` | NVSM stress — DGX only; see note below | Hybrid / Exhaustive |
| `stream` `memtester` | CPU memory bandwidth + DRAM integrity | Exhaustive |
| `stress-ng` | CPU stress | Exhaustive |
| `stressapptest` | Extended memory integrity | Exhaustive |
| `fio` | Local NVMe / shared storage | Exhaustive |
| `ethr` | North-south management + storage NIC | Exhaustive |
| `nvloom` | MNNVL fabric — optional / exploratory | Exhaustive |
| `mnubergemm` | Burn-in | Hybrid / Exhaustive |
| `llm-pretrain` | Single-node LLM pre-training workload gate | Hybrid / Exhaustive |
| `hpl` `cublasmatmul` | Remediation-only single-node GEMM — run by hand | Remediation |

### Choosing a `BENCHMARKS` list

Pick the set matching the delivery methodology. The default holds only jobs
whose dependencies are always available: `dcgm` uses a host binary, and the
NCCL jobs use the `hpc-benchmarks` image, which `build_containers.sh` pulls
from the public catalog. Jobs whose image has to be built or obtained
(`nvbandwidth`, `nvloom`, `mnubergemm`) are covered in
[containers.md](containers.md) and are added here once their image exists.

**Default — ships as written:**
```bash
BENCHMARKS="dcgm nvbandwidth allreduce alltoall allreduce-nonvlink \
            alltoall-nonvlink"
```

This default assumes an NGC login: `nvbandwidth` is pulled from a private NGC
org, so `./build_containers.sh -L` has to have been run on the head node.
Without it the image never arrives, and a job whose image is missing fails on
every node — the same fleet-wide false failure the `nvsm` note below warns
about. `./build_containers.sh -l` says which images are actually present.

For a sweep with no credentials needed, drop `nvbandwidth` from both lists:

```bash
BENCHMARKS="dcgm allreduce alltoall allreduce-nonvlink alltoall-nonvlink"
CONTAINERS="hpc-benchmarks"
```

**Everything that needs no image beyond `hpc-benchmarks` and no DGX** — the
same list minus `nvsm`, `nvbandwidth`, `nvloom`, `mnubergemm` and the two
remediation GEMMs. This one runs as shipped on any site, credentials or not:
```bash
BENCHMARKS="dcgm-r2 dcgm dcgm-r4 allreduce alltoall allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng stressapptest \
            fio ethr llm-pretrain"
```

**Everything** — the Exhaustive tier plus the optional jobs. Nothing stops you
running this, but read the notes above first: `nvsm` drains a non-DGX cluster
on every node, and `nvloom` has no published image at all — it only exists once
`build_containers.sh -S` compiles it. Both `hpl` and `cublasmatmul` are
remediation tools meant to be submitted by hand against one suspect node, not
swept across a fleet. A sweep of this list takes days per node, and every job
holds the whole node while it runs:
```bash
BENCHMARKS="dcgm-r2 dcgm dcgm-r4 nvbandwidth allreduce alltoall nvsm \
            allreduce-nonvlink alltoall-nonvlink stream memtester \
            stress-ng stressapptest fio ethr nvloom mnubergemm \
            llm-pretrain hpl cublasmatmul"
```

## Burn-in

```bash
RUN_BURNIN=no
BURNIN="mnubergemm"
```

A second list, on top of the sweep. `BURNIN` is a list of jobs in exactly the
same format as `BENCHMARKS` — same directory, same `totalRuns`, same verdict
rules. Both are surveyed on every cycle and both can be in the queue at once.

They are separate lists rather than one longer `BENCHMARKS` because they answer
different questions on different timescales — *does this node work*, in
minutes, and *does it keep working*, in days — and because the queue has to be
able to tell them apart. Each list is submitted under its own Slurm job name,
`bringup-<node>` and `burnin-<node>`, which is what lets the sequencer see them
separately: a burn-in sitting in the queue for three days must not block a
benchmark retry behind it.

What keeps them in order is priority, not a gate: `#SBATCH --nice` in each job
file puts the dcgm gates at `0`, the rest of the sweep at `20`, and burn-in at
`100000` — see [benchmarks.md](benchmarks.md#queue-priority). A benchmark
queued while a burn-in is running goes ahead of the burn-in runs still waiting.
It does **not** interrupt the run already on the node, because every job is
`--exclusive`, so the wait is one ~6-hour run rather than all twelve.

`RUN_BURNIN` ships **off**, and reads like every other switch here: `yes`,
`true`, `1` and `on` enable it, everything else does not. An empty `BURNIN` is
a real answer meaning "no burn-in", so it is not backfilled — but
`RUN_BURNIN=yes` with an empty `BURNIN` is a mistake, and the sequencer traces
it rather than quietly never burning in.

What to expect once it is on: `mnubergemm` is 12 runs of a ~6-hour step,
submitted one job at a time, so a node is under burn-in for about three days —
the plan's 24–72 hour row. Each run is its own job and its own result file, so
an interrupted burn-in resumes at the run it reached rather than starting over.
`status-check.sh` and `daily-report.sh` grow a column for each `BURNIN`
job when the switch is on, and drop it again when it is off, so an unused list
does not leave a permanent `NOT_RUN` column that reads like work outstanding. A
burn-in failure drains with `burn-in` in the reason, because a node that ran
for hours and then stopped is a different finding from one that failed a
collective in fifteen minutes.

While jobs from a list are in the queue, that list is not judged — its result
files are being written right now, and a file with no end marker yet is a job
in progress rather than one that died. `quick-view.txt` shows those as
`IN QUEUE`.

The image has to be there **before** the switch is flipped — `mnubergemm` is in
the default `CONTAINERS` for that reason even though its job does not run by
default. Turning burn-in on at a site that never downloaded it means a
fleet-wide failure on the first cycle instead of a burn-in.

### The `nvsm` note

`nvsm` is deliberately NOT in the default list. It is a DGX-only tool that
ships with DGX OS and only carries platform definition files for DGX platforms,
so on anything else it exits before doing any work ("Failed to find a matching
definition file for this platform") and fails identically on every node — which
means a whole-cluster drain for a tool that was never going to run. GPU stress
is already covered by `dcgm` and `mnubergemm`.

Add it back on a DGX site, where it also needs a passwordless sudoers grant on
every compute node. Put it between the NVLink NCCL jobs and the no-NVLink ones
so a fabric problem does not push a GPU stress test to the back of the queue —
`nvsm` has no fabric dependency and should report early:

```bash
BENCHMARKS="dcgm allreduce alltoall nvsm allreduce-nonvlink alltoall-nonvlink"
```

See [nvsm.md](nvsm.md) for both requirements.

## Container images

`CONTAINERS` is the list `build_containers.sh` builds when no image is named on
the command line. It ships as exactly what the default `BENCHMARKS` list needs
and nothing more; add an image here at the same time as you add the job that
uses it.

Two of the three shipped images live in a private NGC org, so a plain
`./build_containers.sh` on a head node with no credentials builds
`hpc-benchmarks`, fails the other two, and exits non-zero. That is the intended
signal rather than a surprise — the jobs are in the default list, so the images
being absent is a real problem — but it is why `-L` comes first:

```bash
./build_containers.sh -L      # store an nvcr.io key, once per head node
./build_containers.sh         # then build the CONTAINERS list
./build_containers.sh -l      # what is actually present
```

| Image | Jobs that use it | Source |
|-------|-----------------|--------|
| `hpc-benchmarks` | `allreduce`, `alltoall`, both `-nonvlink` variants, `hpl`, `cublasmatmul`, `stream` | Public NGC image |
| `nvbandwidth` | `nvbandwidth` | Private NGC org (needs a login); source build only with `-S` |
| `nvloom` | `nvloom` | No published image; two-pass source build, and only with `-S` |
| `mnubergemm` | `mnubergemm` | Private NGC org (needs a login); NVIDIA-internal, no source build exists |

`dcgm` and `nvsm` are not in this table — they run host binaries and need no image.

```bash
CONTAINERS="hpc-benchmarks nvbandwidth mnubergemm"   # default — needs an NGC login
CONTAINERS="hpc-benchmarks"            # no credentials; drop nvbandwidth and mnubergemm from BENCHMARKS too
CONTAINERS="hpc-benchmarks nvbandwidth nvloom"       # adds the source build — run with -S
CONTAINERS=""                          # build nothing — images already in containers/ or obtained another way
```

An explicitly empty `CONTAINERS=""` means "build nothing" and is left that way
— it is the one setting where empty is a real answer rather than an omission,
so `settings.sh` backfills it only when the key is absent altogether. See
[containers.md](containers.md#which-images-get-built).

`build_containers.sh -A` builds everything the script knows about regardless of
this setting, and naming images as arguments overrides it.

## Pause switches

```bash
PAUSE_JOBS=no             # launch_job.sh: submit nothing, drain nothing, resume nothing
PAUSE_HEALTH_CHECKS=no    # node_health.sh: run no checks, touch Slurm in neither direction
PAUSE_CONTAINER_COPY=no   # file_copy.sh: start no new rsync into /tmp/containers
```

All three ship off, and read the same way as the drain switches — `yes`, `true`,
`1` and `on` pause, everything else, including a typo and including empty, does
not. A `SETTINGS` written before these existed leaves them empty and keeps
running, which is the right way round: an unreadable value must not stop a
fleet.

These stop the framework *doing* things without unregistering it from BCM. The
triggers keep firing and each action still runs — it reads its switch, does
nothing, and says so. That is deliberate: an unregistered trigger looks exactly
like a broken one, and the state is only visible from `cmsh`. A pause leaves a
trace line on every node saying it is paused, and `trigger-debug.sh` reports it
in section 0 before it walks any of the links.

Nothing is lost across a pause. Results stay on disk, the sweep resumes from
where it stopped rather than restarting, and a `refresh` sentinel set by
`node-health-refresh.sh` is held rather than consumed.

`PAUSE_JOBS` also reaches work already in the queue, because gating submission
alone would leave hours of already-queued benchmarks running:

| | What happens |
|---|---|
| Pending jobs (ours) | Cancelled. They have produced nothing, and the next unpaused sweep queues them again. |
| Running job (ours) | Left to finish, with its job id traced. Killing it turns a part-written result into an `INCOMPLETE` that is indistinguishable from a crash. `scancel <id>` if you need the node back now. |
| Anyone else's job | Untouched. Only jobs named `bringup-<node>` or `burnin-<node>` are ever cancelled. |

`PAUSE_CONTAINER_COPY` likewise stops new copies and lets a detached `rsync`
from an earlier cycle finish — it holds no node and blocks no job.

See [operations.md](operations.md#pausing-everything) for what to expect while
paused.

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

`DRAIN_AFTER_FAILED_HEALTH_CHECK` is the one to leave off longest. A health
check drains on any diff against `valid-config/default`, so a baseline taken
from a node that is itself slightly off, or one check that is per-rack rather
than per-cluster, drains the entire cluster on the first monitoring cycle.
Bring it up only after `bash health-check.sh --summary` reads clean across the
fleet.

The full operational picture — what changes when they are off, what does not,
and which one to turn on first — is in
[operations.md](operations.md#disabling-drains).

## Recovering drains Slurm set itself

```bash
RECOVER_SLURM_DRAINS=yes
RECOVER_REASONS="prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted"
RECOVER_EMPTY_REASON=yes
RECOVER_SETTERS="slurm root"
RECOVER_MAX_ATTEMPTS=3
RECOVER_WINDOW_HOURS=24
RECOVER_RESTART_SLURMD=no
```

Slurm drains nodes for things that are not faults of the node: a prolog that
returned non-zero once, a process the previous job left behind, an epilog that
lost a race, a batch launch that failed while `slurmd` was restarting. Some
drains carry no reason at all. None of these is a broken node, and until this
existed none of them was ever cleared — the only automatic resume in the
framework is the one for drains carrying `DRAIN_MARKER`. Nodes accumulated in
`drained`, the sequencer traced *"node is drain for a reason that is not ours"*
on every cycle, and somebody had to run `scontrol update ... state=RESUME` by
hand, per node, indefinitely.

`slurm-recovery.sh` is what clears them, and both actions use it:
`launch_job.sh` on every monitoring cycle, `node_health.sh` after a clean check
run.

| Setting | Default | Meaning |
|---------|---------|---------|
| `RECOVER_SLURM_DRAINS` | `yes` | The switch. `no` leaves every drain exactly where it is |
| `RECOVER_REASONS` | see above | Case-insensitive ERE. A drain reason matching it is machine-generated |
| `RECOVER_EMPTY_REASON` | `yes` | Treat a drain with no reason recorded as machine-generated |
| `RECOVER_SETTERS` | `slurm root` | Only drains set by these accounts are ever cleared |
| `RECOVER_MAX_ATTEMPTS` | `3` | Recoveries allowed per node inside the window |
| `RECOVER_WINDOW_HOURS` | `24` | The window, counted from `results/<node>/recover.log` |
| `RECOVER_RESTART_SLURMD` | `no` | Restart a dead `slurmd` before resuming a `down*` node |

Unlike the two drain switches above, this one ships **on**. Those take nodes out
of service, so an unreadable value has to mean "don't"; this one puts them back,
and the cost of it being off is the silence the rest of the framework is built
to prevent — a node drained for a failed prolog, testing nothing, forever.

### How an operator's drain is protected

Every reason falls into one of four classes, and only two are ever recoverable:

| Class | What wrote it | Who may clear it |
|-------|---------------|------------------|
| `marker` | this framework's benchmark drain, carrying `DRAIN_MARKER` | `launch_job.sh`, once the benchmarks pass |
| `health` | `node_health.sh` — the reason is a list of check names | `node_health.sh`, on a clean run |
| `machine` | Slurm itself: matches `RECOVER_REASONS`, or is empty | either action |
| `operator` | everything else | nobody |

Three discriminators have to agree before a `machine` drain is cleared:

1. **The reason matches `RECOVER_REASONS`.** An operator's reason is prose —
   `waiting on RMA`, `bad NVLink, do not use` — and does not match.
2. **The account that set it is in `RECOVER_SETTERS`.** A drain set from a named
   admin account is never cleared, whatever its text says.
3. **The state is one we can reason about.** `maint`, `reserved`, `planned` and
   `fail` are left alone; all four are somebody's deliberate arrangement.

The limit, stated rather than papered over: an admin who drains **as root** with
a reason that happens to match `RECOVER_REASONS` is indistinguishable from Slurm
doing it, because Slurm's own drains land under `root` on a BCM cluster.
Discriminator 1 carries that weight, which is why the shipped pattern list is
narrow and is a setting rather than "anything that is not ours". A site that
drains as root with free-text reasons loses nothing; a site that types the word
`prolog` into a drain reason by hand should add its own convention to
`RECOVER_SETTERS`, or turn `RECOVER_EMPTY_REASON` off if bare drains are how
operators take nodes out there.

### Why a resume is not enough on its own

A node put back while still broken is re-drained within the minute, and a script
that does that in a loop is worse than one that does nothing. So a recovery also
has to show the condition cleared:

- `slurmd` is active on the node — resuming a node whose `slurmd` is dead only
  puts it straight back into `down*`. This is the one condition that can be
  repaired here, and only when `RECOVER_RESTART_SLURMD=yes`; it ships off
  because BCM owns that unit.
- No compute processes hold the GPUs. This is the direct test for the
  rogue-process drain. Only GPU processes are looked at — a general "no
  processes owned by `$JOB_USER`" test reads a login shell as a rogue process
  and the node never comes back.
- No jobs are still assigned to the node.

And it is rate-limited: at most `RECOVER_MAX_ATTEMPTS` recoveries inside
`RECOVER_WINDOW_HOURS`, counted from `results/<node>/recover.log`, which is the
only state any of this keeps between runs. Past the cap the drain is left
**exactly as Slurm set it** — deliberately not re-drained under `DRAIN_MARKER`,
which would hand the node to the sequencer's own resume path and start the
flapping again by another route. The node stays out of service with Slurm's
reason on it, and the count is in the trace and in `recover.log`.

### Reading what it did

```bash
grep RECOVER results/*/trigger.log | tail            # what came back, and why
cat results/<node>/recover.log                       # one line per recovery
./trigger-log.sh                                     # recoveries appear as events
```

`launch_job.sh --explain` classifies and reports without resuming anything.

## Retry and drain policy

| Setting | Default | Meaning |
|---------|---------|---------|
| `RETRY_INTERVAL_HOURS` | `1` | Hours between sweeps, measured from the newest result file on the node |
| `MAX_JOB_HOURS` | `7` | A benchmark `RUNNING` longer than this drains the node |
| `DRAIN_WINDOW_MINUTES` | `15` | Only failures newer than this drain |
| `DRAIN_MARKER` | `auto-retry` | Written into every drain reason this framework issues; only drains carrying it are ever cleared automatically |

`DRAIN_WINDOW_MINUTES` has to sit above the BCM monitoring interval or the
drain is missed entirely, and well below `RETRY_INTERVAL_HOURS`. Its purpose is
that without it, `launch_job.sh` would re-drain from stale result files on every
monitoring cycle — a node an operator had just resumed would be pulled straight
back out of service.

`MAX_JOB_HOURS` has to clear the longest single run in `BENCHMARKS` **and**
`BURNIN`, not the longest sweep — each run is submitted as its own job, so what
it is compared against is one job's elapsed time. The binding constraint is
`mnubergemm`, whose step is capped at `6:30:00`; hence `7`.

It is the top of a four-rung ladder that has to stay in order, and only the top
rung lives in `SETTINGS` — the other three are in the `.sbatch`:

| Limit | `mnubergemm` | What it does |
|---|---|---|
| workload's own cap | `--time_to_run 21420` (5:57) | what normally ends the run |
| `STEP_TIMELIMIT` | `6:30:00` | `srun` kills the step; the script still writes its marker |
| `#SBATCH -t` | `6:41:00` | Slurm kills the job, marker or not |
| `MAX_JOB_HOURS` | `7` | the sequencer drains the node for timeout |

Set it below the longest `STEP_TIMELIMIT` and the sequencer drains healthy nodes
for a timeout while the job is still doing exactly what it was asked to do. Set
it far above and a genuinely hung job holds the node until someone notices:

```bash
grep -H STEP_TIMELIMIT jobs/$JOBS/*.sbatch | sort -t= -k2   # longest run in the set
```

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

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

### Reading them from a script

`settings.sh` is sourced, never run. It needs to know where the bringup root is
before it can look for either file, and it takes that from `SETTINGS_HOME`, or
from `home`, or failing both from its own location:

```bash
home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
```

Afterwards `SETTINGS_FILE` holds the path that was actually read, or is empty if
neither file was found. A script that can usefully say which file it read
reports it; nothing treats an empty one as fatal, because the defaults inside
`settings.sh` are a complete working configuration on their own. The two BCM
actions are the exception — they carry `home=` literally and treat a missing
`settings.sh` itself as fatal, since without it `BENCHMARKS` and the drain
switches are simply absent rather than defaulted.

`settings.sh` also defines `setting_enabled`, which is how every yes/no key in
this document is read. There is one implementation so that a value reads the
same way wherever it is tested.

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

Each is a directory *name*, never a path. `settings.sh` joins each one to the
bringup root and leaves `JOBS_DIR`, `HEALTHCHECKS_DIR` and
`PARSERS_DIR` set, so no script has to remember which variable indexes which
directory. They are set rather than exported, like everything else here: this
file is sourced by every check runner, status check and container build in the
tree, and an export would put them into the environment of all of them.

That is the only place those paths are built. Nothing else may rebuild one by
hand from `$JOBS` — a second copy of the join is a second thing to update when
the layout moves, and it will be the one that is missed.

A name that resolves to a directory that does not exist is the failure mode
this whole section is arranged against, because the natural way to write each
of these consumers is a loop, and a loop over a directory that is not there
finds nothing and says nothing — per node, per cycle, silently. So each one
checks the path and writes a reason instead:

| Consumer | On a missing path |
|---|---|
| `node_health.sh` | `ERROR: no health check set at <dir>`, before the loop over `[0-9]*.sh` |
| `launch_job.sh` | traces `EXIT: <dir>/verdict.sh is missing -- it carries the pass/fail rule`, and submits nothing |
| `status-check.sh`, `daily-report.sh` | the same `verdict.sh` check, to stderr |
| `trigger-debug.sh` | reports all three, each name with the directory it resolved to; flags one that does not exist, and one that exists but is empty |

The same rule applies one level down, to the names *inside* these directories:
prefer an explicit check and a written reason over a loop that finds no matches.

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
| `dcgmi-r1` | Software and deployment checks (`dcgmi diag -r 1`) | all |
| `dcgmi-r2` | TTM DCGM gate (`dcgmi diag -r 2`) | TTM |
| `dcgmi-r3` | Hybrid DCGM gate (`dcgmi diag -r 3`) | Hybrid |
| `dcgmi-r4` | Exhaustive gate (`dcgmi diag -r 4`) | Exhaustive |
| `nvbandwidth` | HBM / PCIe / NVLink bandwidth | Hybrid / Exhaustive |
| `allreduce` `alltoall` | NCCL single-node, NVLink scope | Hybrid / Exhaustive |
| `allreduce-forcesharp` | NCCL all-reduce, NVLink scope, NVLS/SHARP required | Hybrid / Exhaustive |
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
whose dependencies are always available: the `dcgmi-r*` jobs use a host binary,
and the NCCL jobs use the `hpc-benchmarks` image, which `build_containers.sh`
pulls from the public catalog. Jobs whose image has to be built or obtained
(`nvbandwidth`, `nvloom`, `mnubergemm`) are covered in
[containers.md](containers.md) and are added here once their image exists.

**Default — ships as written:**
```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 nvbandwidth allreduce allreduce-forcesharp \
            alltoall allreduce-nonvlink alltoall-nonvlink"
```

Two DCGM levels rather than one: `-r 1` is software-only and nearly free, so it
says a node is testable before the sweep spends hours finding out it is not, and
`-r 3` is the deepest level that still fits a normal sweep. See
[benchmarks.md](benchmarks.md#the-dcgmi-gates).

This default assumes an NGC login: `nvbandwidth` is pulled from a private NGC
org, so `./build_containers.sh -L` has to have been run on the head node.
Without it the image never arrives, and a job whose image is missing fails on
every node — the same fleet-wide false failure the `nvsm` note below warns
about. `./build_containers.sh -l` says which images are actually present.

For a sweep with no credentials needed, drop `nvbandwidth` from both lists:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 allreduce allreduce-forcesharp alltoall \
            allreduce-nonvlink alltoall-nonvlink"
CONTAINERS="hpc-benchmarks"
```

**Everything that needs no image beyond `hpc-benchmarks` and no DGX** — the
same list minus `nvsm`, `nvbandwidth`, `nvloom`, `mnubergemm` and the two
remediation GEMMs. This one runs as shipped on any site, credentials or not:
```bash
BENCHMARKS="dcgmi-r1 dcgmi-r2 dcgmi-r3 dcgmi-r4 allreduce \
            allreduce-forcesharp alltoall allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng \
            stressapptest fio ethr llm-pretrain"
```

**Everything** — the Exhaustive tier plus the optional jobs. Nothing stops you
running this, but read the notes above first: `nvsm` drains a non-DGX cluster
on every node, and `nvloom` has no published image at all — it only exists once
`build_containers.sh -S` compiles it. Both `hpl` and `cublasmatmul` are
remediation tools meant to be submitted by hand against one suspect node, not
swept across a fleet. A sweep of this list takes days per node, and every job
holds the whole node while it runs:
```bash
BENCHMARKS="dcgmi-r1 dcgmi-r2 dcgmi-r3 dcgmi-r4 nvbandwidth allreduce \
            allreduce-forcesharp alltoall nvsm allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng stressapptest \
            fio ethr nvloom mnubergemm llm-pretrain hpl cublasmatmul"
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
file puts the dcgmi gates at `0`, the rest of the sweep at `20`, and burn-in at
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
is already covered by `dcgmi-r3` and `mnubergemm`.

Add it back on a DGX site, where it also needs a passwordless sudoers grant on
every compute node. Put it between the NVLink NCCL jobs and the no-NVLink ones
so a fabric problem does not push a GPU stress test to the back of the queue —
`nvsm` has no fabric dependency and should report early:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 allreduce allreduce-forcesharp alltoall nvsm \
            allreduce-nonvlink alltoall-nonvlink"
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
| `hpc-benchmarks` | `allreduce`, `allreduce-forcesharp`, `alltoall`, both `-nonvlink` variants, `hpl`, `cublasmatmul`, `stream` | Public NGC image |
| `nvbandwidth` | `nvbandwidth` | Private NGC org (needs a login); source build only with `-S` |
| `nvloom` | `nvloom` | No published image; two-pass source build, and only with `-S` |
| `mnubergemm` | `mnubergemm` | Private NGC org (needs a login); NVIDIA-internal, no source build exists |

`dcgmi-r*` and `nvsm` are not in this table — they run host binaries and need no image.

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
PAUSE_JOBS=no             # launch_job.sh: submit nothing, drain nothing
PAUSE_HEALTH_CHECKS=no    # node_health.sh: run no checks, touch Slurm in neither direction
PAUSE_CONTAINER_COPY=no   # file_copy.sh: start no new rsync into /tmp/containers
PAUSE_RECOVERY=no         # both actions: clear no drains Slurm set itself
```

All four ship off, and read the same way as the drain switches — `yes`, `true`,
`1` and `on` pause, everything else, including a typo and including empty, does
not. A `SETTINGS` written before these existed leaves them empty and keeps
running, which is the right way round: an unreadable value must not stop a
fleet.

`PAUSE_RECOVERY` is **independent of `PAUSE_JOBS`**, and the two answer different
questions. Stopping the sweep is "put no more work on this cluster"; stopping the
recovery is "leave every drain where it is". Those are separate decisions and
usually made for separate reasons — during a bring-up you often want the drains
cleared while nothing is being submitted, and during an investigation you want
the opposite. So the recovery runs above the `PAUSE_JOBS` gate in
`launch_job.sh`, governed only by its own switch: putting a node back is not
putting work on it.

`node_health.sh` honours `PAUSE_RECOVERY` too, though its own recovery is
reachable only after a clean check run — so `PAUSE_HEALTH_CHECKS=yes` stops that
one as a side effect, for want of the evidence rather than for want of
permission.

### `--explain` reads through a pause

`launch_job.sh --explain` is not stopped by `PAUSE_JOBS`. It writes nothing to
Slurm and nothing to disk beyond its own trace, and "what would a sweep do on
this node" is a question worth being able to ask *precisely* when the sweep is
stopped — while you are looking at a list of drained nodes deciding whether to
lift the pause. It reports the pause, then carries on explaining:

```
PAUSE_JOBS=yes in /home/cmods/bringup/SETTINGS -- explaining anyway; nothing below would run while it is set
```

`--force` is refused instead, and that asymmetry is the point: `--force` would
touch the cluster, `--explain` cannot.

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
RECOVER_REASONS="prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted|node was stopped|not responding|duplicate jobid|gres/gpu count|low socket|low cpus"
RECOVER_EMPTY_REASON=yes
RECOVER_SETTERS="slurm root"
RECOVER_MAX_ATTEMPTS=3
RECOVER_WINDOW_HOURS=24
RECOVER_RESTART_SLURMD=yes
RECOVER_REREGISTER=yes
RECOVER_SLURMD_WAIT=30
RECOVER_MIN_UPTIME_SECS=300
RECOVER_PREJOB_LOGS=/cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs
RECOVER_PREJOB_SLACK_SECS=900
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

Some of the shipped patterns are not job failures at all, and they are worth
spelling out because they look like hardware faults and are usually not:

- **`Node was stopped by <user>`** and **`Not responding`.** Somebody rebooted or
  power-cycled the node, and Slurm drained it for going away. These arrive in
  racks at a time, because that is how people reboot. The node is fine once it is
  back; what it needs is a resume, and often a `slurmd` restart first — see
  [Restarting slurmd](#restarting-slurmd). The one thing that makes this safe to
  automate is that **the recovery runs on the node itself**: a node that is still
  off, or still booting, is not running the action that would resume it.

- **`Duplicate jobid`.** `slurmd` registered with `slurmctld` carrying a job the
  controller believes is finished, or belongs elsewhere — a job record left in
  `/var/spool/slurmd` across a reboot, a controller failover or restart that
  replayed state the node had already moved past, or a node that came back
  before the epilog for its last job completed. The node is fine; the two ends
  disagree about one job id. A resume re-registers it and the disagreement is
  gone. If a node earns this repeatedly, the stale spool file is the thing to
  look at — the recovery will not delete it, and the attempt cap is what stops
  the loop.
- **`gres/gpu count reported by slurmd (n) lower than configured (m)`** and
  **`Low socket*core*thread count, Low CPUs`.** `slurmd` counted the GPUs or the
  CPUs before they had all finished coming up, so it registered a number that
  was true for a few seconds after boot and is not true now. These two are the
  patterns that can *also* mean genuinely absent hardware, so they are not taken
  on trust — see below.

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
| `RECOVER_RESTART_SLURMD` | `yes` | Restart a `slurmd` that is not running before resuming the node |
| `RECOVER_REREGISTER` | `yes` | Restart a *live* `slurmd` to replace a stale registered count, once the hardware has proved it wrong |
| `RECOVER_SLURMD_WAIT` | `30` | Seconds to wait for `slurmd` to come back from either restart |
| `RECOVER_MIN_UPTIME_SECS` | `300` | Judge nothing on a node that has been up for less than this. `0` disables the floor |
| `RECOVER_PREJOB_LOGS` | BCM's `failed-pre-jobs` | Where the pre-job check writes what it objected to. Empty skips that check |
| `RECOVER_PREJOB_SLACK_SECS` | `900` | How far before the drain a pre-job log may be written and still count as its cause |

Unlike the two drain switches above, this one ships **on**. Those take nodes out
of service, so an unreadable value has to mean "don't"; this one puts them back,
and the cost of it being off is the silence the rest of the framework is built
to prevent — a node drained for a failed prolog, testing nothing, forever.

### Reasons Slurm appends to

Slurm does not always replace a drain reason. When a node stops answering it
**appends to whatever was already there** and signs the result as its own:

```
BF3 TEST BY AIC : Not responding        [slurm@2026-07-30T23:48:16]
AIC UPDATE PXE BIOS : Not responding    [slurm@2026-07-31T04:54:51]
Prolog error : Not responding           [slurm@2026-08-03T11:48:28]
```

The first two are somebody's deliberate arrangement — a node taken for BF3
testing, a node mid-BIOS-update — and they arrive here set by `slurm`, which is
in `RECOVER_SETTERS`, with text ending in a pattern `RECOVER_REASONS` matches.
Both discriminators that normally protect an operator's drain are defeated at
once, by Slurm, without the operator doing anything unusual.

So classification runs on the reason **as it was before the append**: the text
up to ` : Not responding` if there is any, and the whole thing if there is not.
`BF3 TEST BY AIC` is prose and classifies `operator`; `Prolog error` classifies
`machine` as it should; a bare `Not responding` still classifies `machine`. The
same base reason is what the readiness checks are told about, so a count or
rogue-process drain is still recognised underneath an append.

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

### A rogue process drain names its process

The drain reason is `rogueprocess` and stops there. The thing it objected to is
written down in one place only — BCM's pre-job health check log. There are two
directories and only one of them is the right one:

```
pre-post-job-logs/all-pre-jobs/job.114250.tmp    # every run, pass or fail
pre-post-job-logs/failed-pre-jobs/job.114250.log # only the failures
```

`RECOVER_PREJOB_LOGS` points at the second, and the newest `job.*.log` in it is
what gets read:

```
HealthCheckForWlmJob healthchecks for: 114250
========= ink50-dh01-h03-16 ========
rogueprocess is FAIL, /usr/sbin/sshd (cmods)/* 503852 */
Pre-job health checks have failed
```

That is a **login session**, and it holds no GPU, so the readiness test below —
which looks only at GPU compute processes, deliberately — cannot see it. Without
reading this log the recovery resumes the node, the next job's pre-job check
finds the same session, Slurm drains it again, and that repeats until
`RECOVER_MAX_ATTEMPTS` is spent. `recover.log` would say "resumed" three times
and never name the thing that was actually blocking the node.

The drain reason for one of these usually does not say `rogueprocess` at all —
it says **`Prolog error`**, because the pre-job check is what the prolog runs and
Slurm only records that the prolog failed. Both spellings trigger this check, and
`Prolog error` is the one that fires in practice.

So the drain reads the newest log in that directory, takes the command, user and
pid out of each `FAIL` line, and asks whether that process is still there:

- **Gone.** Resume, which is the common case — the session ended and the drain is
  stale.
- **Still running.** Hold, with `sshd (cmods) pid 503852, named by
  job.114250.log` in the trace, and **spend no attempt**. The node comes back on
  its own the cycle after the session ends. It would have been re-drained anyway;
  the difference is that the reason is now visible instead of showing up as three
  silent resumes.

Two things stop this holding a node over something unrelated, and both matter
because **nothing prunes `failed-pre-jobs/`** — the newest log there can be a
record of an incident that ended weeks ago:

- **The log has to be from around this drain.** Its mtime must be no earlier than
  the drain timestamp less `RECOVER_PREJOB_SLACK_SECS` (900). An older log is a
  different incident and is not read as this one's cause.
- **The pid *and* the user have to match.** Pids get reused, and the flagged
  command is often one the node runs anyway — matching `/usr/sbin/sshd` alone
  would match the `sshd` daemon itself, on every node, forever. So the user has
  to place it too: either it owns the process, or it appears in the arguments, as
  it does in `sshd: cmods [priv]`.

Both failures are deliberately one-sided. If either check says no, the node is
resumed exactly as it was before this existed — the worst case is the flap we
started with, not a good node held out of service on a bad match.

This does mean a long-lived `cmods` session keeps its node drained. That is the
honest outcome: BCM's check will fail every job on that node until the session
goes away, so the node is not usable either way. Set `RECOVER_PREJOB_LOGS=` to
skip the check and go back to resuming regardless.

### Restarting slurmd

Two different conditions here are repaired by restarting `slurmd`, and both go
through the same path:

- **`slurmd` is not running**, which is why the node is `down*`. On a node that
  was rebooted out from under Slurm this is usually not "stopped" but
  **`failed`** — `slurmd` tried to start too early or too often on the way up and
  systemd gave up on it. `RECOVER_RESTART_SLURMD` governs this.
- **`slurmd` is running but registered the wrong counts**, above.
  `RECOVER_REREGISTER` governs this.

`systemctl reset-failed slurmd` runs before the restart, always. A unit that has
tripped systemd's start limit **refuses `restart` outright** until that counter
is cleared — `Start request repeated too quickly` — so a plain restart is exactly
the thing that does not work on the node that needs it most. Then it polls up to
`RECOVER_SLURMD_WAIT` seconds for the unit to come back, and only resumes if it
does. If it does not, the node is held, the unit state goes into the trace, and
the log names `journalctl -u slurmd -n 50` as the next step.

The `slurmd` repair runs **before** the "no jobs assigned" and "no compute
processes" gates, which is deliberate and is the one ordering here worth knowing.
A job assigned to a node whose `slurmd` died needs that `slurmd` back to carry on
— `slurmstepd` survives the restart and the job continues — and waiting for the
job to clear first would mean waiting on a job that cannot progress. The *resume*
still waits: the node stays drained until the job is gone, and comes back on a
later cycle. Only the restart jumps the queue.

`RECOVER_RESTART_SLURMD` used to ship **off**, on the grounds that BCM owns that
unit. It now ships **on**, because the restart is only ever reached on a node
that has already passed every gate above it: up long enough to have finished
booting, drained, no jobs assigned, no compute processes on the GPUs, and a drain
reason that classified as `machine`. Restarting `slurmd` on a node in that state
is what an operator does by hand, and it was being done by hand, per node, across
whole racks. A site that would rather it were not can set it back to `no`; the
trace then names the node and says what it would have done.

### Nothing is judged mid-boot

Every number below is read off the node, and on a node that is still coming up
every one of them is still moving. A GPU count taken forty seconds into boot is
not evidence of anything, and restarting `slurmd` underneath a boot that has not
finished is a second race laid over the first one.

So the first readiness check is whether the node has finished booting at all,
and it gates *every* class, not just the count drains:

- **Uptime is at least `RECOVER_MIN_UPTIME_SECS`** (default 300), read from
  `/proc/uptime`. Set it to `0` to disable the floor.
- **`systemctl is-system-running` is not `initializing`, `starting`,
  `stopping` or `maintenance`.** This outlasts any uptime guess on a slow boot —
  a node still bringing up its GPU driver at eight minutes is caught by this and
  not by the floor. `degraded` counts as up: some unit failed, but boot is over,
  and that is a health check's business rather than this. Anything systemd
  cannot answer is not read as "still booting".

Neither is a failure. The node is held with the reason written to
`recover.log`, **no attempt is spent**, and the next monitoring cycle picks it up
a few minutes later, by which time the numbers have stopped moving.

### A count drain is checked against the hardware

The GRES and CPU count drains are the only ones where the node can prove the
drain wrong, because the thing in dispute is a number it can go and read. So
these two are not resumed on the strength of the reason text alone, the way
every other `machine` reason is:

| Source | GPUs | CPUs |
|--------|------|------|
| What the node has now | `nvidia-smi -L` | `slurmd -C`, falling back to `nproc --all` |
| What the config asks for | the configured count in Slurm's own reason, else `Gres=` from `scontrol show node` | `CPUTot=` from `scontrol show node` |

The GRES reason has two spellings in the field and both are read:

```
gres/gpu count reported by slurmd (7) lower than configured (8)
gres/gpu count reported lower than configured (0 < 4)
```

`slurmd -C` is used rather than `lscpu` because it is precisely what `slurmd`
*would* register, which is the number under argument.

Two outcomes, and the split is the whole point:

- **The hardware is short.** The drain is currently correct and a resume would
  only earn it again on the next registration. The node is held, the counts go
  into the trace (`only 7 of 8 GPUs are present`), and **no attempt is spent**.
  Before this, a node genuinely missing a GPU burned all three of its
  `RECOVER_MAX_ATTEMPTS` discovering that, three times, and the log said only
  that it had been resumed and drained again. Naming a missing GPU as a
  *hardware fault* is still `14-nvidia-smi-cuuid.sh`'s job, under the `health`
  class — a different class, cleared by a different caller, untouched by this.
- **The hardware is all there.** Then `slurmctld` is holding a count from a
  registration taken before it was, and **a resume does not ask for a new one**
  — which is why these nodes came back to `idle` and drained again on the spot.
  What replaces the cached count is a `slurmd` restart, so `RECOVER_REREGISTER`
  restarts it, waits up to `RECOVER_SLURMD_WAIT` for it to come back, and
  only then resumes. Restart before resume, not after: a registration carrying
  the old number arriving after the resume would simply re-drain the node.

Unlike `RECOVER_RESTART_SLURMD`, this one ships **on**. That switch restarts a
`slurmd` that is merely *not answering*, which is a guess about a unit BCM owns;
this one only ever fires on an idle, drained node whose own hardware has
contradicted the count that drained it — and the drain it clears cannot clear
itself. Turning it off leaves the resume in place without the re-registration,
which is the old behaviour, and the trace says so on every cycle.

The restart needs no separate rate limit: it only happens on the path that ends
in a resume, and that path is already capped at `RECOVER_MAX_ATTEMPTS` inside
`RECOVER_WINDOW_HOURS`.

Three answers are kept apart here, and conflating any two of them gets a node
wrong:

- **A count of zero is a count.** `(0 < 4)` is the common spelling on this fleet
  — `slurmd` registered with no GPUs at all — and if the driver is still down,
  `nvidia-smi -L` reports zero and *means* it. That is a short count, and it
  holds.
- **`nvidia-smi` failing is the node agreeing with the drain.** Not an absence of
  evidence: the tool is there and cannot enumerate anything, which is precisely
  what the drain complains about. Holds, and names it.
- **The tool not being installed proves nothing.** No `nvidia-smi`, no
  `scontrol`, no configured count to compare against — the recovery falls back
  to what it did before any of this existed and resumes on the reason text,
  rather than holding a node out of service over a number it could not get.

### Why a resume is not enough on its own

A node put back while still broken is re-drained within the minute, and a script
that does that in a loop is worse than one that does nothing. So a recovery also
has to show the condition cleared:

- The node has finished booting, as above.
- `slurmd` is active on the node — resuming a node whose `slurmd` is dead only
  puts it straight back into `down*`. Repaired here when
  `RECOVER_RESTART_SLURMD=yes`, which is the default; see
  [Restarting slurmd](#restarting-slurmd).
- No compute processes hold the GPUs. Only GPU processes are looked at — a
  general "no processes owned by `$JOB_USER`" test reads a login shell as a rogue
  process and the node never comes back. What the pre-job check *did* object to
  is read from its own log instead, [above](#a-rogue-process-drain-names-its-process).
- No jobs are still assigned to the node.
- A count drain is contradicted by the hardware, as above — checked last, so a
  `slurmd` restart can never happen under a live job or a busy GPU.

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

## Reporting

| Setting | Default | Meaning |
|---------|---------|---------|
| `SCAN_JOBS` | empty | Worker processes `status-check.sh` and `daily-report.sh` judge the fleet with. Empty or `0` means one per core |

Both reports derive every cell from the log on each read — the framework never
stores a verdict, so tightening a gate re-judges the fleet. That is the design,
and it means a report is thousands of independent judgements. `verdict-scan.sh`
spreads them across `SCAN_JOBS` workers, because one shell doing all of them in
sequence is what made these reports slow on a large cluster, not the reading.

The default is one worker per core, which is where it stops getting faster on
every machine measured: the work is process startup and small reads, so past
the core count the workers are only competing with each other. Two reasons to
set it explicitly:

- **Lower it** if the head node is shared, or the reports run from cron
  alongside something that matters. A report is never urgent enough to take
  every core on a scheduler node.
- **Raise it** only if the results tree is on high-latency storage — NFS with
  many small files is the case where workers spend their time waiting rather
  than computing, and more of them than cores can help.

It changes nothing about what is reported. The scan's output is folded and
sorted before it is printed, so two runs at different `SCAN_JOBS` produce
identical reports.

### The verdict cache

Both reports keep judged verdicts in `results/.result_cache.<mode>`, which turns
a repeat run from minutes into about a second on a large fleet. There is no
setting for it: it either tells the truth or it is a bug. How the key works, and
why that makes it safe, is in
[operations.md#the-verdict-cache](operations.md#the-verdict-cache).

The files are derived and disposable:

```bash
rm -f results/.result_cache.*      # rebuilt on the next run
./status-check.sh --no-cache       # or bypass it for one run
./daily-report.sh --no-cache
```

Reach for either when you suspect the *cache* rather than the gate — a restore
that reset mtimes, a clock that moved backwards. If a `--no-cache` run disagrees
with a cached one, that is a bug worth reporting, not a cache worth clearing.

## Extra environment for every job

| Setting | Default | Meaning |
|---------|---------|---------|
| `JOB_ENV` | empty | Space-separated `NAME=VALUE`, added to the environment of every `BENCHMARKS` and `BURNIN` job |

For tuning that belongs to the site rather than to any one benchmark, so it does
not have to be pasted into a dozen `.sbatch` files and kept in step:

```sh
JOB_ENV="NCCL_DMABUF_ENABLE=0"
```

`launch_job.sh` appends these to the `sbatch --export` it already uses for
`RESULT_FILE`, and each job's `srun --export=ALL` carries them on into the
container. Nothing else in the tree reads `JOB_ENV`: not the health checks, not
`build_containers.sh`, not the parsers. `settings.sh` is sourced by all of them,
so a variable exported there would land in all of them too — which is why this
is one named list handed to one command rather than a general "export whatever
is in `SETTINGS`" mechanism.

### The job file wins

A variable that the job's own `.sbatch` exports is **not** overridden by
`JOB_ENV`. The `export` in the job file runs after `sbatch` has handed over the
environment, so it is last to write.

That is the right way round. `allreduce-nonvlink.sbatch` has to run with
`NCCL_P2P_DISABLE=1`; a site-wide setting that could flip it would turn the
non-NVLink benchmark into a second NVLink benchmark, which passes and tests
nothing. Per-job values are the test definition, and `JOB_ENV` is the
environment around it.

What was wrong with this before it was written down is that the override was
silent — a `SETTINGS` line that did nothing looked exactly like one that
worked. `launch_job.sh` now traces the collision when it submits:

```
NOTE: JOB_ENV sets NCCL_P2P_LEVEL, but allreduce.sbatch exports its own -- the job file's value is what runs.
```

To change one of those, edit the job file. To change something no job names,
use `JOB_ENV`. `grep -n '^export' jobs/$JOBS/*.sbatch` lists which is which.

### What is rejected

Each entry must be `NAME=VALUE`, where the name is a normal shell identifier and
the value contains only `A-Za-z0-9` and `_.:/+@%-`. Anything else is dropped,
with a line in `trigger.log` saying so, and the sweep runs without it.

The submission is built as a string and run through `su - $JOB_USER -c`, so
everything in `JOB_ENV` is shell that root has arranged to have executed on
every node. Hence an allowlist rather than a list of forbidden characters:
`NCCL_X=0;id` is a plausible typo, and a blocklist has to be right about every
metacharacter at once. It also settles globbing — no `*` or `?` survives to be
expanded. Commas are excluded for a second reason: `--export` is itself
comma-separated, so a value carrying one would silently split into two entries.

A value that genuinely needs a comma or a space belongs in the `.sbatch`, which
is a file rather than a list.

`trigger-debug.sh` section 0 reports the effective list and names any entry that
will be dropped, so a bad line is visible without waiting for a cycle that
happens to submit something.

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

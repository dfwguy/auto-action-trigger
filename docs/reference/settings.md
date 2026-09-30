# Settings (`SETTINGS`, `SETTINGS.default`)

Every key, its default, and what a valid value looks like. Why any of it is
arranged this way is in [explanation/](../explanation/) — each section links to
the page that carries its reasoning.

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
leaves unset is filled in there, so a `SETTINGS` only has to carry the lines the
site actually changed, and one written against an older release does not break
when a new key is added. See
[explanation/architecture.md#upgrading-through-a-tarball-drop](../explanation/architecture.md#upgrading-through-a-tarball-drop).

Editing `SETTINGS.default` in place works until the next tarball drop overwrites
it. Do it once and forget, and the site's configuration silently reverts on an
upgrade.

Every yes/no key in this file is read by `setting_enabled`: `yes`, `true`, `1`
and `on` are affirmative, and everything else — including a typo and including
empty — is not.

## Reading them from a script

`settings.sh` is sourced, never run. It takes the bringup root from
`SETTINGS_HOME`, or from `home`, or failing both from its own location:

```bash
home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
```

Afterwards `SETTINGS_FILE` holds the path that was actually read, or is empty if
neither file was found. Nothing treats an empty one as fatal, because the
defaults inside `settings.sh` are a complete working configuration on their own.
The agent and its three steps are the exception in one respect only: they treat
a missing `settings.sh` as fatal, because a defaulted empty benchmark or check
list reads as "everything passing" on every node. They resolve their own
location like everything else.

## Which set of things to run

| Setting | Default | Directory | Contents |
|---------|---------|-----------|----------|
| `JOBS` | `nvl72` | `jobs/$JOBS/` | The `.sbatch` files `launch_job.sh` submits — see [reference/jobs.md](jobs.md) |
| `HEALTHCHECKS` | `nvl72` | `health-checks/$HEALTHCHECKS/` | One file per check, run by `node_health.sh` — see [reference/health-checks.md](health-checks.md) |
| `PARSERS` | `nvl72` | `parsers/$PARSERS/` | `verdict.sh`: the pass/fail rule and the bandwidth floors. `spectrum-x` also ships, for RoCEv2 fabrics whose NCCL plugin reports `SPCX` rather than `IB` -- see [explanation/judging-benchmarks.md#the-plugin-name-is-a-property-of-the-fabric](../explanation/judging-benchmarks.md#the-plugin-name-is-a-property-of-the-fabric) |

Each is a directory *name*, never a path. `settings.sh` joins each to the
bringup root and leaves `JOBS_DIR`, `HEALTHCHECKS_DIR` and `PARSERS_DIR` set;
nothing else may rebuild one by hand. Why they are three variables rather than
one `PLATFORM`, and what a name resolving to a missing directory does, is in
[explanation/platform-sets.md](../explanation/platform-sets.md).

## The benchmark list

| Setting | Default | Meaning |
|---------|---------|---------|
| `BENCHMARKS` | see below | Ordered list of jobs to run. Everything in it without a passing result is queued once an hour, in listed order |

A name with no `jobs/$JOBS/<name>.sbatch` behind it is skipped with a line in
the trace rather than failing.

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 dcgmi-r4 nvbandwidth allreduce \
            allreduce-forcesharp alltoall allreduce-nonvlink \
            alltoall-nonvlink llm-pretrain llm-pretrain-solo"
```

The default assumes an NGC login, because `nvbandwidth` is pulled from a private
org, plus a staged NeMo image and populated `LLM_HF_HOME` for the two LLM jobs.
The catalog of what is available is
[reference/jobs.md](jobs.md#the-job-catalog); choosing a list for a site is
[how-to/enable-a-benchmark.md](../how-to/enable-a-benchmark.md).

## Benchmark pass floors

The five NCCL bandwidth gates, in GB/s:

| Setting | Default | Job |
|---------|---------|-----|
| `VERDICT_MIN_PEAK_BW_ALLREDUCE` | `683` | `allreduce` |
| `VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP` | `665` | `allreduce-forcesharp` |
| `VERDICT_MIN_PEAK_BW_ALLTOALL` | `623` | `alltoall` |
| `VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK` | `93` | `allreduce-nonvlink` |
| `VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK` | `83` | `alltoall-nonvlink` |

### LLM step time ceilings

| Setting | Default | Job |
|---------|---------|-----|
| `VERDICT_MAX_STEP_MS_LLM_PRETRAIN` | `3480` | `llm-pretrain` |
| `VERDICT_MAX_STEP_MS_LLM_SOLO` | `3510` | `llm-pretrain-solo`, across all four copies |

Milliseconds, compared against the **median** iteration of the run, so the
init and CUDA-graph-capture iterations do not move it. `0` skips the check.

Both started as **estimates**: +5% of a single healthy GB300 tray, which
measured 3310 ms at four GPUs and 3341 ms per solo copy. A 2,013-node fleet has
since put the median at 3320 ms and 3355 ms — within 0.5% of that one tray — so
they are now an observed band rather than a guess, and the shipped values stand.
See
[explanation/llmb.md#judging-the-step-time](../explanation/llmb.md#judging-the-step-time).

Neither is what catches a run that stopped part-way, which has a healthy median
over the iterations it managed. `VERDICT_MIN_LLM_ITERATIONS` in
`parsers/$PARSERS/verdict.sh` does that, and ships as `50` — the recipe's whole
run. See
[explanation/llmb.md#a-run-that-stopped-early](../explanation/llmb.md#a-run-that-stopped-early).

All five bandwidth floors read out-of-place busbw at the largest message size actually run, which
is also what `daily-report.sh` prints in those columns, so a cell and a floor
compare directly. The `-nonvlink` pair is measured on a **100 GB/s compute
plane**; a site on a different link speed has different numbers.

A floor that reaches the gate empty means `settings.sh` was not sourced. That is
reported as `bandwidth floor is not set -- check SETTINGS`, not skipped.

Every other gate — dcgmi, nvbandwidth stability, STREAM, the llm-pretrain spread
— lives in `parsers/$PARSERS/verdict.sh`. Why these five are settings and those
are not is in
[explanation/judging-benchmarks.md#floors-are-a-property-of-the-hardware](../explanation/judging-benchmarks.md#floors-are-a-property-of-the-hardware).

## Burn-in

`RUN_BURNIN`, the switch, lives in
[Run switches](#run-switches) below, next to the rest — it is the one
opt-in (default `no`) among a block that otherwise defaults to running.

| Setting | Default | Meaning |
|---------|---------|---------|
| `BURNIN` | `mnubergemm` | A second list, same format and same rules as `BENCHMARKS` |
| `BURNIN_HOURS` | `24` | Shared campaign target across every job in `BURNIN`, in validated hours. `0` disables the gate — `totalRuns` per job is the only cap left |

`totalRuns` (the generic per-job run-count literal, see
[add-a-benchmark.md](../how-to/add-a-benchmark.md)) is a per-job ceiling under
`BURNIN`, not the completion signal — `BURNIN_HOURS` is. With more than one job
in `BURNIN`, they alternate: each cycle picks the eligible job with the fewest
passed runs so far, ties broken by `BURNIN`'s own order. See
[explanation/sequencing.md#burn-in](../explanation/sequencing.md#burn-in).

`mnubergemm-pulse` ships alongside `mnubergemm` and is **not** in the default
list. It runs the same workload on a slow square wave, and is added by naming
it: `BURNIN="mnubergemm mnubergemm-pulse"`. The two are comparable in
wall-clock validated hours now — both are credited by `--time_to_run` the same
way — but not in delivered load: half of each pulse run is idle. See
[../explanation/burn-in-waveform.md#two-jobs-not-one](../explanation/burn-in-waveform.md#two-jobs-not-one).

An empty `BURNIN` is a real answer meaning "no burn-in", so it is not
backfilled. `RUN_BURNIN=yes` with an empty `BURNIN` is traced as a mistake.

Both lists are surveyed on every cycle and both can be in the queue at once,
under the Slurm job names `bringup-<node>` and `burnin-<node>`. What that
separation buys, and what to expect once the switch is on, is in
[explanation/sequencing.md#two-lists](../explanation/sequencing.md#two-lists).

The image has to be there **before** the switch is flipped: build `mnubergemm`
when you build the rest, even though its job does not run by default.

## Continuous re-runs

| Setting | Default | Meaning |
|---------|---------|---------|
| `CONTINUE_RUNNING_JOBS` | `""` | A third list, lowest priority of the three. Empty means off, same as `BURNIN` |
| `CONTINUE_RUNNING_FREQUENCY` | `6` | Hours between re-runs of a job here, once it is `DONE` |

Every job in this list is one slot (`<job>.txt`), re-run on this flat cadence
forever — `totalRuns` does not apply, unlike `BENCHMARKS` and `BURNIN`. It
exists to watch a result stay consistent as the cluster changes, not to
collect a fixed number of samples.

`BENCHMARKS` and `BURNIN` both take priority: this tier is only ever
considered once both have nothing pending. A job listed here that is *also*
in `BENCHMARKS` or `BURNIN` gets its failures reclaimed by that higher-priority
list for free — the same result file makes it visible to that list's own
survey, so `CONTINUE_RUNNING_FREQUENCY` has no effect until that list is done
with it again. A job listed **only** here has nothing to hand a failure back
to, and is traced as a `WARNING` for exactly that reason. See
[explanation/sequencing.md#continuous-re-runs](../explanation/sequencing.md#continuous-re-runs).

## Container images

There is **no setting for which images to build**. `build_containers.sh` takes
them on the command line, and every `.sqsh` in `CONTAINER_DIR` is cached on
every node — one place decides, and the copy has no opinion. Why, and what the
`CONTAINERS` key that used to be here cost, is
[explanation/containers.md#what-gets-built-is-what-you-ask-for](../explanation/containers.md#what-gets-built-is-what-you-ask-for).

| Image | Jobs that use it | Source |
|-------|-----------------|--------|
| `hpc-benchmarks` | `allreduce`, `allreduce-forcesharp`, `alltoall`, both `-nonvlink` variants, `hpl`, `cublasmatmul`, `stream` | Public NGC image |
| `nvbandwidth` | `nvbandwidth` | Private NGC org (needs a login); source build only with `-S` |
| `nvloom` | `nvloom` | No published image; two-pass source build, and only with `-S` |
| `mnubergemm` | `mnubergemm` | Private NGC org (needs a login); NVIDIA-internal, no source build exists |
| `nemo` | `llm-pretrain`, `llm-pretrain-solo` | Public NGC image. The llmb installer imports the same one — see [how-to/build-containers.md#nemo](../how-to/build-containers.md#nemo) |

`dcgmi-r*` and `nvsm` are not in this table — they run host binaries and need no
image.

### Image versions

| Setting | Default | Names |
|---------|---------|-------|
| `HPC_BENCHMARKS_TAG` | `26.02` | the NGC tag, and the `nvidia+hpc-benchmarks+<tag>-<arch>.sqsh` filename |
| `NVBANDWIDTH_VERSION` | `v0.9` | the git ref for the source build, and the org image's tag |
| `NVLOOM_VERSION` | `v2.0.0` | the git ref; there is no published image |
| `MNUBERGEMM_VERSION` | `26.03-v1.17` | the org image's tag, after its `tensorrt-` prefix |
| `NEMO_TAG` | `26.04.01` | the NGC tag for both LLM jobs' image |

These were literals in `build_containers.sh` until a site needed a different
one. Bumping one changes the **filename** the build produces, and the job files
build that same string — so a bump is two edits, here and in `jobs/$JOBS/`, and
a job that cannot find its image says so rather than running against the old
one. The two LLM jobs are the exception: they glob `nvidia+nemo+*.sqsh` and do
not carry the version at all.

`NEMO_TAG` additionally has to match the recipe the LLM jobs were captured
against — see
[explanation/llmb.md#the-frozen-recipe](../explanation/llmb.md#the-frozen-recipe).

## Health-check cadence

| Setting | Default | Meaning |
|---------|---------|---------|
| `HEALTH_INTERVAL_HOURS` | `4` | How long after a **clean** run `node_health.sh` re-runs the checks |
| `HEALTH_RETRY_INTERVAL_HOURS` | `1` | How long after a run that **found something** it re-runs them |
| `HEALTH_LOG_DIR` | `$BRINGUP_DATA/logs` | Shared, compute-facing root for per-node check output, cadence state and health trace — see [#accounts-and-paths](#accounts-and-paths) |

Whole hours, and `0` on either disables the cadence in the state it applies to —
the checks then re-run only when `health-check.sh --refresh` sets the sentinel,
which is how this tree behaved before the cadence existed.

The interval is measured from `$HEALTH_LOG_DIR/<node>/.last-check`, which also records
which of the two applies. `health-check.sh --explain` prints the resulting due
times across the fleet. Why two intervals and no backoff:
[explanation/health-cadence.md#choosing-the-two-intervals](../explanation/health-cadence.md#choosing-the-two-intervals).

Set `HEALTH_LOG_DIR` to a share mounted directly by compute nodes when health
traffic should not traverse the controller. `node_health.sh` also redirects its
stderr to `<node>/stderr.log`; routine permission and tool errors therefore do
not fan into systemd-journald or centralized syslog. Failure to create or open
the configured path is still reported to the service journal once.

## The agent and the watchdog

| Setting | Default | Meaning |
|---------|---------|---------|
| `AGENT_INTERVAL_MINUTES` | `2` | How often `bringup-agent.timer` fires one cycle, on every host. Must divide 60 — `1 2 3 4 5 6 10 12 15 20 30` — because the timer is `OnCalendar=*:0/N`; anything else is refused and 2 is used |
| `SUPERVISOR_INTERVAL_MINUTES` | `2` | How often `bringup-supervisor.timer` fires the watchdog on the head node. Also how often the fleet's node views are rewritten — see [explanation/the-fleet-snapshot.md](../explanation/the-fleet-snapshot.md) |
| `HEARTBEAT_STALE_MINUTES` | `10` | A heartbeat older than this, on an `idle` or `drained` node, is armed again |
| `ARM_BATCH` | `200` | Most nodes one watchdog cycle reaches at once; the rest are deferred to the next. `0` is no cap. Every arm is an ssh from one host — see [explanation/the-agent-and-the-watchdog.md#arming-is-bounded](../explanation/the-agent-and-the-watchdog.md#arming-is-bounded) |
| `ARM_RETRY_MINUTES` | `10` | Shortest gap between two arming attempts on the same node |
| `ARM_MAX_ATTEMPTS` | `3` | Attempts inside `ARM_WINDOW_HOURS` before the node is left for an operator |
| `SLURM_SNAPSHOT_MAX_AGE_MINUTES` | empty | How old a node view may be before the agent stops deciding from it. Empty is three watchdog cycles, floored at five minutes. A node past it says so every cycle and acts on nothing — see [explanation/the-fleet-snapshot.md#no-view-is-not-an-empty-queue](../explanation/the-fleet-snapshot.md#no-view-is-not-an-empty-queue) |
| `ARM_WINDOW_HOURS` | `24` | The window that count is taken over |
| `SUPERVISOR_HOST` | *empty* | Which host arms the others. Empty means whichever claims `results/.supervisor-owner` and keeps it fresh; naming one settles it where two hosts read as head. See [explanation/the-agent-and-the-watchdog.md#only-one-watchdog](../explanation/the-agent-and-the-watchdog.md#only-one-watchdog) |

On a large fleet the interval is also the load lever: every read in a cycle is
multiplied by the node count, and 2,016 nodes on two minutes is 17 reads a
second for each file a cycle touches. See
[explanation/the-agent-and-the-watchdog.md#what-a-cycle-costs-the-share](../explanation/the-agent-and-the-watchdog.md#what-a-cycle-costs-the-share).

The two intervals are read only at install time: they are substituted into the
unit files by `agent/install-agent.sh`, so changing one means re-running it —
across the fleet for `AGENT_INTERVAL_MINUTES`, on the head node for the other.
Everything else here is read fresh on every cycle.

A value that is not a whole number of minutes is warned about and replaced with
the default rather than stopping the fleet. Why these numbers and not others is
[explanation/the-agent-and-the-watchdog.md#choosing-the-three-numbers](../explanation/the-agent-and-the-watchdog.md#choosing-the-three-numbers).

## Privilege

| Setting | Default | Meaning |
|---------|---------|---------|
| `PRIV_SCONTROL` | `sudo` | How `scontrol update` is issued. `sudo` uses the rule in `agent/sudoers.default`; `direct` is for a site that gave `JOB_USER` Slurm `AdminLevel=Operator` |

Anything other than `direct` reads as `sudo`. Only `update` goes through it —
`scontrol show node`, `scontrol listjobs` and `scontrol show hostlist` are reads
and run unprivileged. There is deliberately no autodetection; see
[explanation/running-unprivileged.md#draining-without-root](../explanation/running-unprivileged.md#draining-without-root).

## Reaching more than one node

| Setting | Default | Meaning |
|---------|---------|---------|
| `FANOUT_TOOL` | `auto` | `auto` prefers `clush` and falls back to `pdsh`; `clush` or `pdsh` pins it and fails with a named reason when that one is missing |
| `FANOUT_CONNECT_TIMEOUT` | `10` | Seconds to reach a node, passed as `-t` to either tool. `0` is no limit |
| `FANOUT_COMMAND_TIMEOUT` | `60` | Seconds a command may run on a node, passed as `-u` to either tool. `0` is no limit, which is what both tools do unasked |

Neither tool bounds the command by default, and a node with a hung mount answers
the ssh and then never returns — one of those holds a whole fan-out open. A node
dropped by the timeout still has a stale heartbeat and is armed by the watchdog
on its next cycle, so the limit defers a node rather than losing one. See
[explanation/architecture.md#a-fan-out-is-bounded](../explanation/architecture.md#a-fan-out-is-bounded).

`fanout.sh` is the only place either is invoked, and every trace line that
reaches a node says which was used. A pinned value that is not installed is a
refusal rather than a silent fall back — a site that chose `clush` and is
quietly getting `pdsh` has a preference nobody honoured. See
[explanation/architecture.md#reaching-nodes-is-clush-or-pdsh](../explanation/architecture.md#reaching-nodes-is-clush-or-pdsh).

## Run switches

| Setting | Default | Set to `no`, stops |
|---------|---------|-------|
| `RUN_JOBS` | `yes` | `launch_job.sh`: submit nothing, drain nothing |
| `RUN_HEALTH_CHECKS` | `yes` | `node_health.sh`: run no checks, touch Slurm in neither direction |
| `RUN_CONTAINER_COPY` | `yes` | `file_copy.sh`: start no new rsync into `NODE_CONTAINER_DIR`. It is reread every cycle; changing it back to `yes` resumes copying on the next cycle |
| `RUN_RECOVERY` | `yes` | `launch_job.sh` and `node_health.sh`: clear no drains Slurm set itself |
| `RUN_ARMING` | `yes` | `supervisor.sh`: arm no node. Agents already running carry on cycling, and their node views are still written |
| `RUN_BURNIN` | `no` | The odd one out: default is *off*, and `yes` is what starts burn-in rather than what stops something already running. See [Burn-in](#burn-in) |
| `REQUIRE_BCM_BOOTSTRAP_READY` | `no` | Opt in to requiring BCM's command URL and service, `slurmd`, and the job identity before `launch_job.sh` submits |

Renamed from `PAUSE_*` — the five above used to default `no` (meaning: running)
and this flipped both the name and the polarity, so `RUN_JOBS=yes` reads the
same as the old `PAUSE_JOBS=no` did. A site with an old name still in
`SETTINGS` gets a `WARNING:` in the trace naming the equivalent, every cycle,
until it's updated — nothing silently stops being read.

A malformed value for any of these fails toward the switch staying **on**
(`setting_disabled()`, not `! setting_enabled()`, is what reads them) — the
same direction a typo in the old `PAUSE_*` value failed toward, so a mistake
costs nothing rather than halting the fleet.

`RUN_RECOVERY` is **independent of `RUN_JOBS`**. `RUN_JOBS=no` also cancels
this framework's pending jobs and leaves its running one to finish.
`RUN_ARMING` is the odd one out among the first five: it stops the watchdog
restarting a node that has *stopped*, and does nothing to a node that is
running — to stop one of those see
[how-to/arm-a-node.md#disarming-a-node](../how-to/arm-a-node.md#disarming-a-node).
It is scoped to the arming alone, and deliberately: the watchdog's other job is
writing the node view every agent decides from, and a switch that stopped that
would stop the whole fleet a snapshot age later.

`REQUIRE_BCM_BOOTSTRAP_READY` is deliberately off by default. When enabled on
a BCM-managed cluster, a node waits until `/var/spool/cmd/my.cmd.url` is
non-empty, `cmd.service` and `slurmd.service` are active, and `JOB_USER` resolves.
Each command probe is limited to `BCM_BOOTSTRAP_PROBE_TIMEOUT_SECS` (default
`5`); a timeout is treated as not ready and the next agent cycle retries. A
cluster that does not use BCM should leave the switch off.

`--explain` is stopped by none of them, and neither is the heartbeat: all five
are read deep inside a cycle, after `results/<node>/.heartbeat` is already
touched, so a node with any of them set to `no` still reads fresh in
`overall_report.sh`. A node reading DOWN is its *timer* that stopped, which
none of these switches touch — that is `pause-agents.sh`, a different
mechanism entirely. See
[explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means](../explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means).
The reasoning for all of them is in
[explanation/sequencing.md#what-a-pause-is-for](../explanation/sequencing.md#what-a-pause-is-for);
what to expect while paused is
[how-to/pause-and-resume.md](../how-to/pause-and-resume.md).

## Drains

| Setting | Default | Meaning |
|---------|---------|---------|
| `DRAIN_AFTER_FAILED_HEALTH_CHECK` | `no` | `node_health.sh`: mismatch against the baseline |
| `DRAIN_AFTER_FAILED_BENCHMARK` | `no` | `launch_job.sh`: failed sweep, and `MAX_JOB_HOURS` |

Both ship off, and anything not affirmative reads as off: for two switches that
decide whether nodes get taken out of service, an unreadable value has to mean
"don't". These replace the old `NODRAIN` file, which is gone.

`DRAIN_AFTER_FAILED_HEALTH_CHECK` is the one to leave off longest — a health
check drains on any diff against `valid-config/default`, so a baseline taken
from a node that is itself slightly off drains the entire cluster on the first
cycle. Which to turn on first, and in what order, is
[how-to/manage-drains.md](../how-to/manage-drains.md).

## Recovering drains Slurm set itself

| Setting | Default | Meaning |
|---------|---------|---------|
| `RECOVER_SLURM_DRAINS` | `yes` | The switch. `no` leaves every drain exactly where it is |
| `RECOVER_REASONS` | see below | Case-insensitive ERE. A drain reason matching it is machine-generated |
| `RECOVER_EMPTY_REASON` | `yes` | Treat a drain with no reason recorded as machine-generated |
| `RECOVER_SETTERS` | `slurm root` | Only drains set by these accounts are ever cleared |
| `RECOVER_MAX_ATTEMPTS` | `3` | Recoveries allowed per node inside the window |
| `RECOVER_WINDOW_HOURS` | `24` | The window, counted from `results/<node>/recover.log` |
| `RECOVER_RESTART_SLURMD` | `yes` | Restart a `slurmd` that is not running before resuming the node |
| `RECOVER_REREGISTER` | `yes` | Restart a *live* `slurmd` to replace a stale registered count |
| `RECOVER_SLURMD_WAIT` | `30` | Seconds to wait for `slurmd` to come back from either restart |
| `RECOVER_MIN_UPTIME_SECS` | `300` | Judge nothing on a node up for less than this. `0` disables the floor |
| `RECOVER_PREJOB_LOGS` | BCM's `failed-pre-jobs` | Where the pre-job check writes what it objected to. Empty skips that check |
| `RECOVER_PREJOB_SLACK_SECS` | `900` | How far before the drain a pre-job log may be written and still count as its cause |

```bash
RECOVER_REASONS="prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted|node was stopped|not responding|duplicate jobid|gres/gpu count|low socket|low cpus"
RECOVER_PREJOB_LOGS=/cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs
```

Unlike the two drain switches above, this one ships **on**: those take nodes out
of service, this one puts them back. `slurm-recovery.sh` is what clears them,
and both actions call it. What each shipped pattern means, what has to be true
before a drain is cleared, and how an operator's drain is protected from all of
it, is [explanation/drain-recovery.md](../explanation/drain-recovery.md).

### Steps that outlive their own kill

| Key | Default | Value |
|-----|---------|-------|
| `RECOVER_DOWN_UNKILLABLE` | `no` | `yes` marks a node `DOWN` when a step has survived its own kill. **Gates the action only** — the condition is detected and traced either way |
| `RECOVER_UNKILLABLE_REASONS` | `Kill task failed\|unkillable` | Case-insensitive ERE. The drain reasons that mean Slurm has already failed to kill what is on the GPUs |
| `RECOVER_UNKILLABLE_AFTER_SECS` | `3600` | How long the same GPU pids must persist before the node is taken out of service |

```bash
RECOVER_DOWN_UNKILLABLE=no
RECOVER_UNKILLABLE_REASONS="Kill task failed|unkillable"
RECOVER_UNKILLABLE_AFTER_SECS=3600
```

Ships **off**, unlike the recovery above: marking a node `DOWN` releases
whatever allocation it still holds, and on a multi-node job that is every rank,
not just the wedged node's. Both conditions have to hold — the pid set unchanged
for `RECOVER_UNKILLABLE_AFTER_SECS`, *and* no job on the node still inside its
own time limit. A job with no time limit never qualifies.

The switch gates only the `scontrol update state=DOWN`. Detection runs
regardless, and a node that meets both conditions says so in its trace with the
switch off — a site that never lets this tree take nodes out of service, which
is what `DRAIN_AFTER_FAILED_*=no` above says, still needs to know a node is
wedged rather than watching it hold silently. The reason it writes
classifies as `operator`, so nothing in this tree clears it afterwards; see
[explanation/drain-recovery.md#a-step-that-outlives-its-own-kill](../explanation/drain-recovery.md#a-step-that-outlives-its-own-kill)
and, for what to do with the node,
[how-to/clear-an-unkillable-step.md](../how-to/clear-an-unkillable-step.md).

## Restricting which nodes run jobs

| Setting | Default | Meaning |
|---------|---------|---------|
| `NODE_FILTER` | empty | The nodes the sequencer submits benchmarks on. Empty means every node |

```bash
NODE_FILTER=""                          # every node
NODE_FILTER="ink40-dh4-*"               # one rack
NODE_FILTER="ink40-dh4-* ink41-dh4-*"   # two
NODE_FILTER="ink40-dh4-0[1-9]"          # part of one
```

**These are shell globs, not regular expressions** — deliberately not an ERE,
unlike `RECOVER_REASONS`. Patterns are separated by whitespace, a node matches
if **any** of them matches, and the comparison is against `$HOSTNAME` as Slurm
knows it, so the short name rather than an FQDN.

It gates benchmarks and burn-in only: health checks, reporting, container copy
and drain recovery still run everywhere. `--force` does not open it; `--test`
does; `--explain` reads through it. See
[explanation/sequencing.md#site-switches-are-not-timing-gates](../explanation/sequencing.md#site-switches-are-not-timing-gates).

To take a node out of the framework entirely, use `EXCLUDE_NODES` below, or
disarm it — see
[how-to/arm-a-node.md#disarming-a-node](../how-to/arm-a-node.md#disarming-a-node).
Bear in mind that the watchdog arms an idle node back unless `EXCLUDE_NODES` or
`NODE_FILTER` takes it out of the set it considers.

## Hosts that are not compute nodes

| Setting | Default | Meaning |
|---------|---------|---------|
| `EXCLUDE_NODES` | empty | Hosts that cannot run a job at all — the head node. Empty leaves the detection to the host itself |

```bash
EXCLUDE_NODES=""                  # detect it, do not declare it
EXCLUDE_NODES="nscale-hn1"        # one head node
EXCLUDE_NODES="*-hn[0-9]"         # an HA pair, by shape
```

Shell globs and whitespace separated, read the same way as `NODE_FILTER`, and
matched against `$HOSTNAME`.

This is not `NODE_FILTER` with a wider reach. `NODE_FILTER` says *this node is
not in the set we are sweeping right now*; `EXCLUDE_NODES` says *Slurm will
never schedule a job here*, and so it stops everything rather than benchmarks
alone:

| | `NODE_FILTER` excludes it | `EXCLUDE_NODES` matches it |
|---|---|---|
| Benchmarks and burn-in | not submitted | not submitted |
| Health checks | still run | not run |
| `status-check.sh`, `daily-report.sh` | still reported | no row |
| `trigger-log.sh`, `trigger-debug.sh` | still read | skipped, and counted |
| `--test` / `--force` | `--test` opens it | neither opens it |

A host that matches never needed to be listed for the exclusion to happen: on
each cycle `launch_job.sh` also asks the local systemd whether this host runs
`slurmctld` and has no `slurmd`, and writes `results/<node>/.not-a-compute-node`
when it does. The reports skip a directory holding that marker, which is how
they exclude a host without asking Slurm about it. Listing the host in
`EXCLUDE_NODES` says the same thing deliberately, one cycle earlier, and from
the head node rather than from the host.

Both are undone the same way: clear the setting, delete the marker file. The
next normal cycle on that node removes a stale marker by itself.

Why the detection is that particular question, and not `sinfo -N -n`, is in
[explanation/sequencing.md#a-host-that-is-not-a-compute-node](../explanation/sequencing.md#a-host-that-is-not-a-compute-node).

## Retry and drain policy

| Setting | Default | Meaning |
|---------|---------|---------|
| `RETRY_INTERVAL_HOURS` | `1` | Hours before a job may run again, measured from that job's own result file |
| `RETRY_BACKOFF` | `yes` | Add an hour to that window for each failure a run already has on disk. `no` keeps the flat window |
| `RETRY_BACKOFF_MAX_HOURS` | `12` | Ceiling on the widened window. Ignored, with a warning, if it is not a whole number of hours at or above `RETRY_INTERVAL_HOURS` |
| `SUBMIT_RETRY_BASE_MINUTES` | `2` | Initial upper bound for a failed submission's node-local retry; each node chooses a stable delay from the upper half so the fleet spreads out |
| `SUBMIT_RETRY_MAX_MINUTES` | `30` | Ceiling for the exponentially increasing submission retry bound |
| `SUBMIT_CIRCUIT_FAILURES` | `10` | Matching recent submission diagnostics needed for the watchdog to stop fleet-wide submissions temporarily; `0` disables the circuit breaker |
| `SUBMIT_CIRCUIT_WINDOW_MINUTES` | `5` | How recent per-node submission failures must be to count toward the circuit threshold |
| `SUBMIT_CIRCUIT_HOLD_MINUTES` | `10` | How long an opened fleet submission circuit prevents new `sbatch` calls |
| `MAX_JOB_HOURS` | `7` | A benchmark `RUNNING` longer than this drains the node |
| `SUBMIT_ONLY_WHEN_IDLE` | `yes` | Submit only to a node whose Slurm state is exactly `idle`. `no` submits regardless, and a job for a drained node sits `PENDING` until an operator clears it |
| `DRAIN_WINDOW_MINUTES` | `15` | Only failures newer than this drain |
| `INFLIGHT_GRACE_MINUTES` | `30` | How long a submitted job that never started is believed before the controller is asked about it |
| `DRAIN_MARKER` | `auto-retry` | Written into every drain reason this framework issues; only drains carrying it are ever cleared automatically |

`DRAIN_WINDOW_MINUTES` has to sit above `AGENT_INTERVAL_MINUTES` or the drain
is missed entirely, and well below `RETRY_INTERVAL_HOURS`.

`RETRY_BACKOFF` slows down a job that keeps failing and nothing else: it never
stops retrying, never idles the node's other benchmarks, and does not decide
whether the node drains. `--force` opens it. See
[explanation/sequencing.md#backing-off-a-job-that-keeps-failing](../explanation/sequencing.md#backing-off-a-job-that-keeps-failing).

The `SUBMIT_*` settings cover failures before a job exists and are therefore
separate from workload retry. `--force` does not bypass them: a timeout may mean
Slurm accepted the job but lost the reply, and retrying immediately can create a
duplicate. See [when sbatch refuses a submission](../explanation/sequencing.md#when-sbatch-refuses-a-submission).

`MAX_JOB_HOURS` has to clear the longest single run in `BENCHMARKS` **and**
`BURNIN`, not the longest sweep. The binding constraint is `mnubergemm`, whose
step is capped at `6:30:00`; hence `7`.

```bash
grep -H STEP_TIMELIMIT jobs/$JOBS/*.sbatch | sort -t= -k2   # longest run in the set
```

It is the top of a four-rung ladder that has to stay in order, and only the top
rung lives in `SETTINGS`:

| Limit | `mnubergemm` | What it does |
|---|---|---|
| workload's own cap | `--time_to_run 21420` (5:57) | what normally ends the run |
| `STEP_TIMELIMIT` | `6:30:00` | `srun` kills the step; the script still writes its marker |
| `#SBATCH -t` | `6:41:00` | Slurm kills the job, marker or not |
| `MAX_JOB_HOURS` | `7` | the sequencer drains the node for timeout |

`INFLIGHT_GRACE_MINUTES` is the only setting that trades a chatty controller
against an idle node; see
[explanation/sequencing.md#when-a-marker-goes-stale](../explanation/sequencing.md#when-a-marker-goes-stale).

## Getting out of the way

**Experimental.** Off on every site, and the behaviour and setting names may
change. See
[explanation/sequencing.md#getting-out-of-the-way](../explanation/sequencing.md#getting-out-of-the-way)
for what turning it on commits a site to.

| Setting | Default | Meaning |
|---------|---------|---------|
| `GET_OUT_OF_THE_WAY` | `no` | Have the head-node watchdog cancel our running job on a node when somebody else is queued for that node |
| `GET_OUT_OF_THE_WAY_AFTER_MINUTES` | `5` | How long the other job must have been pending before the node is given up |
| `GET_OUT_OF_THE_WAY_POLL_MINUTES` | `5` | How often the watchdog scans for waiters. One stamp for the fleet, at `results/.yield-check` |

The supervisor/watchdog decides and executes the cancel on the head node, for
every node at once. A compute node neither scans for waiters nor runs `scancel`;
it only reads the `.yielded` breadcrumb afterward. See
[explanation/the-fleet-snapshot.md#what-moved-to-the-head-node](../explanation/the-fleet-snapshot.md#what-moved-to-the-head-node).
Only a job named `bringup-<node>` or `burnin-<node>`, owned by `JOB_USER`, and
confirmed `RUNNING` on the wanted node by the queue itself is ever cancelled —
no marker is taken as evidence. Nothing is drained, and the cancelled run is
re-queued like any other interrupted attempt. The node is left a note at
`results/<node>/.yielded` so its next cycle says why its job went.

Both intervals are minutes and the second one is a cost control: a cycle with a
job running otherwise costs the controller nothing at all. The whole design,
including what counts as somebody waiting, is
[explanation/sequencing.md#getting-out-of-the-way](../explanation/sequencing.md#getting-out-of-the-way).

## Reporting

| Setting | Default | Meaning |
|---------|---------|---------|
| `SCAN_JOBS` | empty | Worker processes `status-check.sh` and `daily-report.sh` judge the fleet with. Empty or `0` means one per core |

It changes nothing about what is reported: the scan's output is folded and
sorted before it is printed, so two runs at different `SCAN_JOBS` produce
identical reports. Lower it if the head node is shared; raise it only if the
results tree is on high-latency storage.

There is no setting for the verdict cache — it either tells the truth or it is a
bug. See
[explanation/verdicts-and-the-cache.md](../explanation/verdicts-and-the-cache.md).

## Extra environment for every job

| Setting | Default | Meaning |
|---------|---------|---------|
| `JOB_ENV` | empty | Space-separated `NAME=VALUE`, added to the environment of every `BENCHMARKS` and `BURNIN` job |

```sh
JOB_ENV="NCCL_DMABUF_ENABLE=0"
```

Nothing else in the tree reads `JOB_ENV`: not the health checks, not
`build_containers.sh`, not the parsers. A variable the job's own `.sbatch`
exports is **not** overridden by it, and the collision is traced on submission:

```
NOTE: JOB_ENV sets NCCL_P2P_LEVEL, but allreduce.sbatch exports its own -- the job file's value is what runs.
```

`grep -n '^export' jobs/$JOBS/*.sbatch` lists which variables a job file owns.
Why the job file wins is in
[explanation/sequencing.md#the-job-file-wins](../explanation/sequencing.md#the-job-file-wins).

### What is rejected

Each entry must be `NAME=VALUE`, where the name is a normal shell identifier and
the value contains only `A-Za-z0-9` and `_.:/+@%-`. Anything else is dropped,
with a line in `trigger.log` saying so, and the sweep runs without it.

It is an allowlist rather than a blocklist because the submission is built as a
string and run through `su - $JOB_USER -c`. Commas are excluded for a second
reason: `--export` is itself comma-separated, so a value carrying one would
silently split into two entries. A value that genuinely needs a comma or a space
belongs in the `.sbatch`, which is a file rather than a list.

`trigger-debug.sh` section 0 reports the effective list and names any entry that
will be dropped.

## Accounts and paths

| Setting | Default | Meaning |
|---------|---------|---------|
| `JOB_USER` | `cmods` | The account Slurm jobs are submitted as, and the owner `RESULTS_DIR` and `HEALTH_LOG_DIR` are handed to |
| `BRINGUP_HOME` | `/cluster/bringup` | Where this tree lives on the cluster |
| `BRINGUP_DATA` | `/cluster/bringup-data` | Where results, logs, container images and the health baseline live — independent of `BRINGUP_HOME`, so the checkout and the data it produces can sit on different filesystems |

`JOB_USER` is the only place the account is named; the optional LLMB capture
workspace derives from it, so moving to an automation account of its own is
one line. Why it is worth keeping it that way — and what a hardcoded account
broke last time — is
[explanation/architecture.md#one-account-name](../explanation/architecture.md#one-account-name).

Neither default writes to `/home`. A site that wants the old layout, or any
other, overrides `BRINGUP_HOME`/`BRINGUP_DATA` — or any one path below them —
in its own `SETTINGS`.

The account has to exist on every compute node with a working login shell:
root's cycles reach it through `su - $JOB_USER -c`, and an operator running a
sweep by hand has to *be* it. It also needs whatever Slurm association the site
requires, or every `sbatch` is refused — that refusal is captured in
`trigger.log` rather than swallowed.

Nothing needs `BRINGUP_HOME` to find the tree; the scripts resolve their own
location. It is read by the jobs, which cannot, and checked by
`agent/install-agent.sh`, which warns when the tree it is arming from is not the
deployed one. See
[reference/layout.md#runtime-paths](layout.md#runtime-paths).

### Where results, logs and the baseline live

| Setting | Default | Meaning |
|---------|---------|---------|
| `RESULTS_DIR` | `$BRINGUP_DATA/results` | Per-node benchmark and agent output — see [layout.md#runtime-paths](layout.md#runtime-paths) |
| `HEALTH_LOG_DIR` | `$BRINGUP_DATA/logs` | Per-node health check output |
| `VALID_CONFIG_DIR` | `$BRINGUP_DATA/valid-config` | The health baseline `set-valid-default.sh` writes and every check is judged against |

Each defaults under `BRINGUP_DATA` but is independently overridable — a site
can put `RESULTS_DIR` on a compute-facing share while leaving `HEALTH_LOG_DIR`
and `VALID_CONFIG_DIR` at the `BRINGUP_DATA` default, for instance. Clearing
any of them is safe at any time — see
[layout.md#result-path-ownership](layout.md#result-path-ownership).

### Where the images live

| Setting | Default | Meaning |
|---------|---------|---------|
| `CONTAINER_DIR` | `$BRINGUP_DATA/containers` | The shared image directory, as the compute nodes mount it |
| `CONTAINER_DIR_HEAD` | `$CONTAINER_DIR` | The same directory as the head node mounts it |
| `CONTAINER_STAGE_DIR` | `$BRINGUP_DATA/container-src` | Source staging for `-S`/`-F`/`-B`, as the compute nodes mount it |
| `CONTAINER_STAGE_DIR_HEAD` | `$CONTAINER_STAGE_DIR` | The same, as the head node mounts it |
| `NODE_CONTAINER_DIR` | `/opt/containers` | Node-local cache `file_copy.sh` rsyncs `CONTAINER_DIR` into. `/opt` survives a reboot; change this one line to move it |

Separate from `BRINGUP_HOME` because the images are tens of gigabytes and a
site's bulk share is usually not the filesystem the checkout is on. Set only
the two non-`_HEAD` ones unless the head node reaches that share by a
different path than the nodes do — `/mnt/server-1-data` against `/data`, say —
which nothing can detect and which fails silently.
[explanation/containers.md#one-share-two-mount-points](../explanation/containers.md#one-share-two-mount-points)
is the whole argument.

## LLM pre-training

| Setting | Default | Meaning |
|---------|---------|---------|
| `LLM_HF_HOME` | empty | Required host path to the non-empty, pre-staged Llama Hugging Face cache used by `llm-pretrain` and `llm-pretrain-solo` |

`launch_job.sh` exports this path to both batch jobs. They mount it at
`/hf-cache` and run offline. An empty value is allowed globally so sites can
disable both LLM jobs; either job refuses with a named reason if it is enabled
without the setting. See
[how-to/enable-llm-pretrain.md#2-stage-the-llama-cache](../how-to/enable-llm-pretrain.md#2-stage-the-llama-cache).

## llmb-run

These are capture/install settings for `build_llmb.sh` and `llmb_check.py`.
Neither LLM batch job reads them at runtime.

| Setting | Default | Meaning |
|---------|---------|---------|
| `LLMB_INSTALL` | `/home/$JOB_USER/llmb` | Where `build_llmb.sh` installs the collection, image and tokenizer cache. Empty means no install |
| `LLMB_REF` | `v26.06.01` | The `dgxc-benchmarking` tag `build_llmb.sh` installs, and the version `-l` gates on. Empty skips the gate |
| `LLMB_BIN` | empty | Directory holding the `llmb-run` executable. Empty is searched for |
| `LLMB_CONFIG` | empty | Path to `cluster_config.yaml`. Empty is searched for |
| `LLMB_IMAGES` | empty | Directory holding the `.sqsh` images. Empty is searched for |
| `LLMB_HF` | empty | The install's Hugging Face cache. Empty is searched for; copy the resolved directory into `LLM_HF_HOME` to remove the runtime dependency |

The four empty ones exist to adopt an install this tree did not build, whose
layout it cannot assume. `./build_llmb.sh -l` runs the search, prints what
answered and exits non-zero if anything is missing. See
[explanation/llmb.md#adopting-an-existing-install](../explanation/llmb.md#adopting-an-existing-install).

`LLMB_INSTALL` is deliberately outside `BRINGUP_HOME`, and `build_llmb.sh`
refuses to install into it or below it.

Everything else `llmb-run` needs lives in `cluster_config.yaml` inside the
install, written by the collection's own installer — not in `SETTINGS`. See
[reference/llmb-run.md](llmb-run.md).

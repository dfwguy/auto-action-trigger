# Recovering drains Slurm set itself

Slurm drains nodes for things that are not faults of the node: a prolog that
returned non-zero once, a process the previous job left behind, an epilog that
lost a race, a batch launch that failed while `slurmd` was restarting. Some
drains carry no reason at all.

None of these is a broken node, and until this existed none of them was ever
cleared — the only automatic resume in the framework is the one for drains
carrying `DRAIN_MARKER`. Nodes accumulated in `drained`, the sequencer traced
*"node is drain for a reason that is not ours"* on every cycle, and somebody had
to run `scontrol update ... state=RESUME` by hand, per node, indefinitely.

`slurm-recovery.sh` is what clears them, and both actions use it:
`launch_job.sh` on every monitoring cycle, `node_health.sh` after a clean check
run. The settings are in
[reference/settings.md#recovering-drains-slurm-set-itself](../reference/settings.md#recovering-drains-slurm-set-itself);
the operator commands are in
[how-to/manage-drains.md](../how-to/manage-drains.md).

## What the shipped patterns actually mean

Some of them are not job failures at all, and they are worth spelling out
because they look like hardware faults and are usually not:

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
  on trust — see [A count drain is checked against the
  hardware](#a-count-drain-is-checked-against-the-hardware).

## Reasons Slurm appends to

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

## How an operator's drain is protected

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

## A rogue process drain names its process

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
rogueprocess is FAIL, /usr/sbin/sshd (cmods)/* 503852 */
rogueprocess is FAIL, /usr/bin/bash (nvis-ib), /usr/sbin/sshd (nvis-ib)/* 14533, 14535 */
dmesg is FAIL, /* 4790 */ matches for regex: hardware error
```

Three things about that format, each of which has to be handled or the check is
worse than useless:

- **Several commands share one pid list.** The second line names two commands and
  two pids, and they are not paired — a longer list may carry four pids for two
  commands. So the two are matched as *sets*: any listed pid that is still alive
  and matches any listed command counts.
- **`/* … */` does not always hold pids.** The `dmesg` check puts its *match
  count* between the same markers. Reading `4790` as a pid would hold a node over
  whatever process happened to inherit that number, so only lines from the
  `rogueprocess` check are read for processes at all.
- **Most of these drains do not say `rogueprocess`.** They say `Prolog error`,
  because the prolog is what runs the check and Slurm records only that the
  prolog failed. Both reasons trigger this, and `Prolog error` is the one that
  fires in practice.

What the log names is typically a **login session**, which holds no GPU, so the
readiness test below — which looks only at GPU compute processes, deliberately —
cannot see it. Without reading this log the recovery resumes the node, the next
job's pre-job check finds the same session, Slurm drains it again, and that
repeats until `RECOVER_MAX_ATTEMPTS` is spent. `recover.log` would say "resumed"
three times and never name the thing that was actually blocking the node.

So the recovery reads the newest log in that directory, takes the command, user
and pid out of each `FAIL` line, and asks whether that process is still there:

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

## What failed is written down either way

Whatever the outcome, the checks that failed go into the trace:

```
recover note: the pre-job check that drained ink50-dh01-h20-35 failed on [dmesg];
nothing it named is still running, so this is a resume rather than a hold.
Repeats here are that check failing again, not this.
```

Only `rogueprocess` can be re-evaluated from outside — a `dmesg` flood or a
failed IB check cannot be, and holding on one would be a deadlock, since a
drained node never runs another prolog to prove itself clear. So those resume,
and the attempt cap is what stops the flapping.

What the note buys is that the flapping is no longer anonymous. A node drained
three times in a day whose reason only ever reads `Prolog error` looks like a
recovery that will not settle; the same node saying `failed on [dmesg]` is a
hardware fault with a ticket to open. The recovery is not the thing to fix in
that case, and the log now says so.

## When nothing names the check

The note above is only written when a log was found and read. There are five
ways for that to fail, and for most of this file's life every one of them
produced the same thing: a resume, with no note, and nothing saying why.

That is worse than it sounds, because the note is the only difference between a
node flapping on a hardware fault and a node flapping on the recovery. A node
that resumes four times in thirty-two hours and never once names a cause looks
like a broken recovery from the outside; the case this section was written from
was `dmesg is FAIL, /* 10 */ matches for regex: blocked for more than` — kernel
hung-task warnings, a hardware fault, and the recovery behaving correctly
throughout. Nobody could tell, because the one line that would have said so was
never written.

So each exit now names itself, and a resume that could not be explained says
that it could not be explained:

| The exit | What the trace says |
|---|---|
| `RECOVER_PREJOB_LOGS` is empty | the site turned the check off |
| the directory is absent on the node | the path does not resolve here |
| no readable `job.*.log` in it | the directory is there and empty |
| the newest log predates the drain | how far, against `RECOVER_PREJOB_SLACK_SECS` |
| the log names no failed check | it was read and explained nothing |

The fourth is the one worth dwelling on, because the rejection is *correct* —
nothing prunes `failed-pre-jobs/`, so an old log is a different incident and
reading it as this drain's cause would be worse than reading nothing. Being
right and being silent are separate questions, and this file had been answering
only the first. The trace now carries the gap in seconds and the slack it was
measured against, so a site whose logs land slightly late can see that it is a
slack problem rather than a missing log.

None of this changes an outcome. Every one of these paths resumed before and
resumes now, at the same rate limit — what changes is that
`grep -i recover results/<node>/trigger.log` answers the question instead of
returning nothing.

### And it has to outlive the trace

Naming the check in `trigger.log` is not enough on its own, because that file is
trimmed to its last 2000 lines once it passes 1 MB, and a node gets a line or
two per monitoring cycle. A busy node loses a day of trace, and what it loses
first is the note explaining a drain that is still on it.

The rack this was found on made the point by itself: `d06-15`, `-18`, `-28` and
`-29` all carried `the pre-job check failed on [dmesg]` from two days earlier,
and `d06-17` — same rack, same fault, same drain — carried nothing, because its
trace had rotated and theirs had not. Reading the two side by side suggested a
difference between the nodes that did not exist.

So the check goes into `recover.log` as well, in a seventh tab-separated field.
That file is bounded too, but by *resumes* rather than by cycles: 500 lines is
years of history on any node that is not flapping, and a node that is flapping
is one this file wants to keep the history for. Field 6 stays the reason Slurm
gave, which is what `overall_report.sh` and the rate limit already key on —
both read `-F'\t'` and neither looks past the fields it names, so older lines
with six fields still read correctly.

## Restarting slurmd

Two different conditions here are repaired by restarting `slurmd`, and both go
through the same path:

- **`slurmd` is not running**, which is why the node is `down*`. On a node that
  was rebooted out from under Slurm this is usually not "stopped" but
  **`failed`** — `slurmd` tried to start too early or too often on the way up and
  systemd gave up on it. `RECOVER_RESTART_SLURMD` governs this.
- **`slurmd` is running but registered the wrong counts.** `RECOVER_REREGISTER`
  governs this.

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

## Nothing is judged mid-boot

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

Neither is a failure. The node is held with the reason written to `recover.log`,
**no attempt is spent**, and the next monitoring cycle picks it up a few minutes
later, by which time the numbers have stopped moving.

## A count drain is checked against the hardware

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

## A drained node has no job of ours to key on

For most of this file's life the sequencer only reached the recovery block when
a job of ours had gone stale — the reasoning being that a drain is what stops
our jobs starting, so the stale branch is where it shows up, and a healthy node
never pays for the query. That reasoning is circular, and the two reasons it
failed on are the two that arrive when there is no job to be stale:

- **`gres/gpu count`** is set at `slurmd` registration, which is boot. Nothing
  of ours has ever been submitted to that node in this cycle or any other since
  the reboot, so there is no marker to go stale.
- **A prolog or rogue-process drain** is usually earned under *somebody else's*
  job. Same absence.

A node that has passed every benchmark is in the same position, and traced
`EXIT: every benchmark passing` on every cycle while sitting `drained` for a
`Prolog error` nobody was going to clear. Once drained it could never acquire a
marker either, because a drained node is never allocated — and in the one case
where a marker did exist, a job pending on the drained node reads as `PENDING`
forever, which the in-flight gate exits on *before* recovery is reached.

So recovery now runs on every cycle that reaches it, which is every cycle where
nothing of ours is running here. The exception is the job that outran
`MAX_JOB_HOURS`: that is the one path that gets this far with a live job, it is
drained immediately below, and recovery would only hold on it.

The cost is one `sinfo -N -n <node>` per node per cycle, which is the price of
seeing a drain at all — the node cannot answer this one about itself, and
`slurm_recover_node` returns `not-drained` and traces nothing on the healthy
majority. See
[sequencing.md#what-the-node-can-answer-by-itself](sequencing.md#what-the-node-can-answer-by-itself).

## Why a resume is not enough on its own

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
  is read from its own log instead,
  [above](#a-rogue-process-drain-names-its-process).
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

## A step that outlives its own kill

Everything above assumes the condition behind a drain eventually clears, so a
hold is temporary and the next cycle is free to look again. One condition never
clears, and it is the one that produces the most convincing-looking hold.

When a step ignores `SIGKILL` for longer than `UnkillableStepTimeout`, slurmd
gives up and Slurm drains the node with `Kill task failed (JobId=… StepId=…)`.
That reason is in the shipped `RECOVER_REASONS` — correctly, because most of the
time the processes do die a moment later and the node is fine. When they do not,
the recovery reaches the GPU-process gate every cycle, finds the same pids, and
writes the same `recover held:` line forever. Nothing is wrong with that
judgement. A resume would be actively harmful: the node would take work while a
previous job's ranks still hold its GPUs.

The case this was built from was a `nvl72` NVLink-only `allreduce`, a job with a
25-minute walltime, whose four `all_reduce_perf` ranks were still on the GPUs
four and a half hours later in state `Rl` — running, not blocked. A rank
spinning inside a CUDA kernel cannot be reaped, because the pending `SIGKILL` is
only delivered when the kernel returns and the kernel is waiting on a peer that
NVLink can no longer reach. The node had been held every 45 seconds since, and
the only thing that would have told anyone was somebody happening to read one
node's `trigger.log`.

So past `RECOVER_UNKILLABLE_AFTER_SECS` the condition is named, and — where the
site allows it — the node is taken out of service and handed over.

The naming and the acting are separate on purpose. `RECOVER_DOWN_UNKILLABLE`
gates only the `scontrol update state=DOWN`; the detection runs either way, and
a node that meets every condition says so in its trace with the switch off. A
site running `DRAIN_AFTER_FAILED_HEALTH_CHECK=no` and
`DRAIN_AFTER_FAILED_BENCHMARK=no` has said it wants this tree to observe and not
to take nodes out of service, and gating the *finding* on the switch would leave
exactly that site with the repeating held line and nothing else — which is the
failure this section exists to fix, not a configuration of it.

When it does act:

- **`DOWN`, not `DRAIN`.** A drained node keeps its allocation, which is exactly
  the state it is already stuck in. Marking it `DOWN` makes slurmctld stop
  waiting for a confirmation slurmd is never going to send, and release the job.
  That is also why this is **off by default**: on a multi-node allocation it
  releases everybody's ranks, not just the wedged node's, and that is a decision
  a site makes rather than inherits.
- **The reason text is the mechanism.** It is written as
  `unkillable job: N GPU process(es) survived …s past their step kill — needs
  manual intervention`, and every word of that is chosen not to match
  `RECOVER_REASONS` and not to contain `DRAIN_MARKER`. Classified back it comes
  out `operator`, which
  [nothing in this tree ever clears](#how-an-operators-drain-is-protected).
  Quote the original `Kill task failed` into it and the class flips to
  `machine`, and the next cycle resumes the node this just condemned — so
  `tests/recover-test.sh` classifies the string the code actually writes, rather
  than a copy of it, and does the same again with Slurm's ` : Not responding`
  appended.
- **Keyed on the pid set, not on elapsed time alone.** The first-seen epoch and
  the pids live in `results/<node>/unkillable.stamp`, the second and last piece
  of state any of this keeps. A changed pid set is a different incident and
  restarts the clock, which is what keeps a node whose steps are being killed
  and replaced normally from accumulating its way to `DOWN`.
- **And Slurm has to agree, independently.** A stationary pid set is suggestive,
  not conclusive — a long job that has settled into a steady set of ranks looks
  identical. So the second proof is asked of Slurm: no job assigned to the node
  may still be inside its own time limit. This is read from `squeue -o '%e'`,
  which is start plus the job's limit as an absolute time, so nothing here
  parses a Slurm duration in a format that varies by release. A step kill can
  fail on one step while the job legitimately carries on with the next, and that
  job is not a wedge.
- **An unlimited job is never enough.** `%e` reports `N/A` when there is no time
  limit, and there is then no limit to have exceeded — no evidence separating a
  wedged step from a long one. Those nodes stay held and go to an operator, as
  does anything else `%e` cannot be read from. The gate is asymmetric on
  purpose: the failure it can cause is a node taken out of service and an
  allocation released, so every unknown resolves to *not that*.
- **Narrowed to the one reason that means Slurm already tried.** Every drain
  holds on busy GPUs; only `RECOVER_UNKILLABLE_REASONS` means slurmd has already
  failed to kill what is on them. A `Prolog error` with live GPU processes is a
  node someone else is legitimately using.

Nothing about this is recorded in `recover.log`. That file is the attempt
history the rate limit reads, and it counts *resumes* — a node marked `DOWN`
resumed nothing, and spending an attempt on it would make the fleet's recovery
budget depend on how many nodes had wedged.

Two limits worth knowing before relying on it. A node already past
`RECOVER_MAX_ATTEMPTS` returns `rate-limited` before the readiness gates run, so
it is never reached here — it is already left for an operator, with a worse
reason on it. And once the node is `DOWN`, every later cycle classifies it
`operator` and traces `recover skipped:`, once per cycle, for as long as it sits
there. That is the same standing-noise trade the rest of this file makes:
a line that repeats is how a node that is not coming back stays visible.

# Every line the trace can write

Four files, one timestamped line per decision, appending rather than truncating
— they are the record, not a status file:

| File | Written by |
|---|---|
| `results/<node>/agent.log` | `agent/node-agent.sh` — [the agent trace](#the-agent-trace) |
| `results/<node>/trigger.log` | `actions/launch_job.sh` — everything up to [the health trace](#the-health-trace) |
| `results/<node>/copy.log` | `actions/file_copy.sh` — [the container copy trace](#the-container-copy-trace) |
| `$HEALTH_LOG_DIR/<node>/health.log` | `actions/node_health.sh` — [the health trace](#the-health-trace) |
| `results/supervisor.log` | `agent/supervisor.sh` — [the watchdog trace](#the-watchdog-trace) |

Reading them across the cluster is `check_trigger-log.sh`, in
[how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md);
this page is what the lines mean.

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
  once per run; if the log is not writable by whoever is running — the common
  case being a tree left root-owned by the years these cycles ran as root — the
  run turns verbose, says so on stderr with the `chown` to fix it, and mirrors
  everything to stdout. A run that can neither write nor speak is the one state
  this whole mechanism exists to make impossible.

The log is trimmed to its last 2000 lines when it passes 1 MB. It gets a line or
two per agent cycle, forever.

## Startup and housekeeping

| Line | When |
|------|------|
| `MANUAL: --force -- hourly gate bypassed[, --all -- passing jobs re-queued too]` | A human ran it. Without this, an hour of off-cadence results reads as the sequencer misbehaving |
| `MANUAL TEST: --test <jobs> -- BENCHMARKS and BURNIN not surveyed this run, no drains, quick-view.txt left alone` | A human ran an ad-hoc job. Replaces the `MANUAL:` line, and is what explains a result in a column the reports do not have — see [how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list](../how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list) |
| `WARNING: <dir> is owned by <user> and not writable by <user>` | A directory left behind by the root cycles. Nothing repairs it now; the `chown` is in the line — see [layout.md#result-path-ownership](layout.md#result-path-ownership) |
| `WARNING: JOB_ENV entry '<pair>' is not NAME=VALUE …  -- dropped` | A rejected `JOB_ENV` entry. The sweep still runs, and the reason it ran without your variable is written next to it — see [settings.md#what-is-rejected](settings.md#what-is-rejected) |
| `EXIT: <tool> not on PATH after 'module load slurm' (PATH=…)` | No Slurm client tools; every check below would have read as a healthy idle node |
| `EXIT: NODE_FILTER='<globs>' … does not match <node> -- no jobs submitted here` | This node is outside the set being tested — see [settings.md#restricting-which-nodes-run-jobs](settings.md#restricting-which-nodes-run-jobs). Written every cycle on purpose: "why is this node not testing" has to be answerable from the node's own trace. Names `--force` when it was passed, so the flag does not look ignored |
| `NODE_FILTER='<globs>' does not match <node>, but --test <jobs> names this node … -- testing anyway` | `--test` opens the filter where `--force` does not. Says the node is outside the swept set, so a result the reports do not cover is explained where it happened |
| `state=<node state> explain=<0\|1>` | The ordinary first line of a working cycle |

## Pause and recovery

| Line | When |
|------|------|
| `EXIT: RUN_JOBS=<value> in <settings file>` | Paused: nothing submitted, drained or archived. Drains Slurm set itself are cleared above this gate, under `RUN_RECOVERY` |
| `RUN_JOBS=<value> ... -- explaining anyway` | `--explain` reads through the pause; it writes nothing either way |
| `recovery paused: RUN_RECOVERY=<value>` | Drains left exactly where they are, whatever `RECOVER_SLURM_DRAINS` says |
| `RUN_JOBS=no: cancelled pending <ids>` | Pending jobs of ours cleared, so a pause reaches the queue and not just submission |
| `RUN_JOBS=no: job <id> still RUNNING -- left to finish` | A running job is not killed; the id is named so an operator can `scancel` it deliberately |
| `--force does not override RUN_JOBS: it is a site switch, not a timing gate.` | Appended when a forced run hits the pause |
| `RECOVER …` / `state after recovery=<state>` | A drain Slurm set itself was cleared and the node state re-read — see [explanation/drain-recovery.md](../explanation/drain-recovery.md) |
| `recover held: … compute processes still on the GPUs (pids …)` | A resume would put work on a node whose GPUs a previous job still holds. The same pids every cycle is a step that outlived its own kill — [how-to/clear-an-unkillable-step.md](../how-to/clear-an-unkillable-step.md) |
| `… unchanged for <n>s of <n>s before this counts as a step that outlived its own kill` | Appended to the held line while the clock runs |
| `… unchanged for <n>s, but <why> -- not a wedged step as far as this can tell` | The pid set qualified but Slurm did not: a job on the node is still inside its time limit, or has no limit at all |
| `… the step outlived its own kill <n>s ago and <node> needs a reboot -- RECOVER_DOWN_UNKILLABLE=no` | Both conditions met, and the switch is off. The finding is named; the node is left exactly as Slurm set it |
| `DOWN <node>: unkillable job: …` | Both proofs agreed and the node was taken out of service. The reason classifies as `operator`, so nothing here clears it — [how-to/clear-an-unkillable-step.md](../how-to/clear-an-unkillable-step.md) |
| `WOULD MARK DOWN <node>: …` | The same, under `--explain`. Nothing was changed |
| `DOWN FAILED <node>: scontrol update state=DOWN -- <output>` | `scontrol` refused it, usually a privilege problem — see [layout.md#slurm-permissions](layout.md#slurm-permissions) |
| `WARNING: <home>/slurm-recovery.sh is missing` | A deployment that predates the file. Named rather than skipped quietly, because its absence is invisible from outside: nodes simply stay drained |

## The queue

| Line | When |
|------|------|
| `EXIT: EXCLUDE_NODES='<globs>' … matches <host>` | The site listed this host as one Slurm will never schedule on — see [explanation/sequencing.md#a-host-that-is-not-a-compute-node](../explanation/sequencing.md#a-host-that-is-not-a-compute-node) |
| `EXIT: <host> runs slurmctld and has no slurmd, so it is a head node` | The same conclusion reached by the host itself. Writes `results/<host>/.not-a-compute-node`, which is what keeps it out of the reports |
| `EXIT: <n> job(s) not ours on <node> -- leaving the node to them` | Somebody else is using the node |
| `queue: bench=<n> burnin=<n> [running=<t>] [<id> <state> <reason>…]` | Every cycle that gets this far. The per-job detail is only rendered for jobs that are not cleanly schedulable, so a healthy cycle keeps this to one line |
| `EXIT: <job> run <n> (job <id>) running here for <n>s -- slurmctld not asked` | The busy cycle |
| `EXIT: <job> run <n> (job <id>) still queued after <n>s -- left alone (<state> <reason>)` | Past the grace, and the node view still carries the job. Carries `scancel <id> && rm <marker>`, both halves: cancelling without clearing the marker leaves the node pinned |
| `<job> run <n> (job <id>) after <n>s: cancelled our job … to get out of the way of <waiter> (<n>s ago)` | The watchdog gave this node up to somebody queued for it, and left the note this line is read from — see [explanation/sequencing.md#getting-out-of-the-way](../explanation/sequencing.md#getting-out-of-the-way) |
| `<job> run <n> (job <id>) after <n>s: gone from the queue with no end marker …` | The same branch with no note: cancelled, killed, or the node was drained under it |
| `EXIT: no <path>/.slurm-view … -- so it is not known whether <job> run <n> is still queued` | The watchdog has stopped writing this node's view. The marker is kept and nothing is archived — see [explanation/the-fleet-snapshot.md#no-view-is-not-an-empty-queue](../explanation/the-fleet-snapshot.md#no-view-is-not-an-empty-queue) |
| `EXIT: <path>/.slurm-view is <n>s old, past the <n>m this trusts …` | The same, from a view that has gone stale rather than one that is missing. Names the `systemctl --user status` to run on the head node |
| `EXIT: <path>/.slurm-view has no end marker …` | A torn read: the watchdog was rewriting the file as this cycle read it. Self-correcting on the next cycle |
| `EXIT: … so it is not known whether a job of ours is already out, and <job> run <n> stays eligible …` | The submission guard had no usable view. Failing closed here is what stops a stale view turning into two jobs on one node |
| `EXIT: $home/slurm-snapshot.sh is missing …` | This node has no way to read what Slurm says, and asking the controller from here is what that file exists to stop. A partial drop |
| `RUN_JOBS=no: job <id> (<name>) is <state> -- pending ones are cancelled from the head node` | What this node can see of its own jobs while paused. The cancel itself is the watchdog's |
| `<job> run <n> was host-launched and Slurm gave it job <id> -- marker filled in` | The id came back from the node view a cycle after the launcher ran — see [explanation/sequencing.md#getting-the-job-id-right](../explanation/sequencing.md#getting-the-job-id-right) |
| `NOTE: <job> run <n> was host-launched and <n> jobs of ours are in the view … none adopted` | Ambiguous, so no id is taken: the wrong one in the marker pins this node to somebody else's job |
| `EXIT: waiting on our own queue [(RUNNING for <t>, limit <n>h)] [<detail>]` | The normal busy cycle. The scheduler's reason for a job that is not cleanly schedulable is appended — this line reads identically whether the job starts in a minute or never, and the reason is the whole difference |

## The survey

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
| `WARNING: CONTINUE_RUNNING_JOBS names <job>, which is not in BENCHMARKS or BURNIN -- its failures have nothing to hand back to, so they will not drain or back off, only retry every <n>h forever.` | An entry in [`CONTINUE_RUNNING_JOBS`](settings.md#continuous-re-runs) with no higher-priority list to reclaim its failures — see [explanation/sequencing.md#continuous-re-runs](../explanation/sequencing.md#continuous-re-runs) |

## Drain, resume and the gates before submitting

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
| `EXIT: <node> is '<state>'[ ('<reason>', set by <user>)] -- Slurm would hold <job> run <n> PENDING rather than run it…` | [`SUBMIT_ONLY_WHEN_IDLE`](../explanation/sequencing.md#submitting-only-to-an-idle-node), closed. Expected on a drained or reserved node, and not a fault |
| `EXIT: node bootstrap is not ready (<items>) -- no job submitted…` | `REQUIRE_BCM_BOOTSTRAP_READY=yes`, and the job identity, BCM command URL, `cmd.service`, or `slurmd.service` is not ready after boot. The next cycle retries without creating an attempt or draining the node |
| `node bootstrap is not ready (<items>) … -- explaining anyway; a real cycle would stop here` | The same gate under `--explain`. The blocker is reported, then downstream gates are evaluated without submitting or draining |
| `the node view still says '<state>', but this cycle resumed the node -- submitting on the state it has now…` | The same gate, opened on a resume the view is too old to know about |
| `backing off: <job> run <n> after <n> failures: <n>h window, <n>m left[; …]` | `RETRY_BACKOFF` is on and a run has waited out more than the flat window. One line for both lists, once a cycle — see [explanation/sequencing.md#backing-off-a-job-that-keeps-failing](../explanation/sequencing.md#backing-off-a-job-that-keeps-failing) |
| `nothing eligible to submit: everything is passing or inside its own retry window (<n>h[, plus an hour per failure to at most <n>h])` | Nothing to do this cycle. The bracketed half appears only when `RETRY_BACKOFF` is on |
| `WARNING: RETRY_BACKOFF=<value> but RETRY_BACKOFF_MAX_HOURS='<value>' … is not a whole number of hours at or above RETRY_INTERVAL_HOURS` | A typo in `SETTINGS`. The flat window is kept rather than stopping the fleet |
| `WOULD SUBMIT <job> run <n>[ (existing <STATUS> result kept as .<fail\|prev><N>.txt)]: <command>` | `--explain` only |
| `submitted <job> run <n>: Submitted batch job <id> [(JOB_ENV: …)]` | Work went out |
| `SUBMIT FAILED <job> run <n>: <sbatch output>` | Work did not go out, and `sbatch` says why |
| `submission retry: <job> run <n> failure <n>, waiting <n>m before another sbatch` | The durable submission-error clock was written; this is separate from workload retry |
| `EXIT: submission backoff after <n> failure(s) …` | No `sbatch` this cycle; the node-local retry delay has not elapsed |
| `EXIT: submission backoff elapsed, but the node view is not newer …` | The previous failure might have followed an accepted job, so a later controller view is required before retrying |
| `EXIT: fleet submission circuit is open …` | Enough nodes reported the same recent submission error that the watchdog temporarily stopped fleet-wide retries |

A new gate gets a line here and a line in the table above it. An `exit 0` with
no explanation is a bug even when the behaviour is correct: most cycles
legitimately have nothing to do, so a node that has silently stopped testing
looks exactly like a node that is quietly idle. See
[explanation/architecture.md#silence-is-the-enemy](../explanation/architecture.md#silence-is-the-enemy).

## The agent trace

`results/<node>/agent.log`, one line per cycle. It answers "did the timer fire,
and did the cycle get as far as the three steps"; what each step then decided is
in that step's own file.

| Line | When |
|------|------|
| `idle: no job here -- file_copy node_health launch_job` | The ordinary line of a working cycle. A step that exited non-zero has `(exit N)` after its name |
| `BUSY: job(s) <ids> running here -- no copy, no health check, no submission` | Any job at all, ours or a neighbour's. The whole cycle stops here — see [explanation/sequencing.md#the-busy-gate](../explanation/sequencing.md#the-busy-gate) |
| `BUSY: 'scontrol listjobs' exited <n> (<output>)` | An inconclusive answer reads as busy, which is the direction that cannot interrupt a running job |
| `EXIT: the cycle that started <n>s ago still holds /tmp/.bringup-agent.lock` | One cycle at a time. A long first container copy is the usual cause, and it detaches, so this is rare |
| `NOTE: cannot open /tmp/.bringup-agent.lock` | The cycle runs anyway, without the one-at-a-time guard, rather than not running |
| `EXIT: scontrol is not on PATH after 'module load slurm' (PATH=…)` | Whether a job is running here cannot be answered, and every step below needs Slurm anyway |
| `WARNING: cannot touch <path>/.heartbeat as <user>` | The watchdog will keep arming this node, because it cannot see that it is alive. Almost always a root-owned `results/<node>` |
| `NOTE: <path> is missing -- skipped` | A step's script is not in the tree. Partial drop, or a stale deployment |

The heartbeat itself is written above every one of these, including `BUSY` and
the lock line: it says the timer fired, never that the cycle did work. See
[explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means](../explanation/the-agent-and-the-watchdog.md#what-the-heartbeat-means).

## The watchdog trace

`results/supervisor.log`, one line per cycle on the head node, plus a line per
node it acted on. Every cycle writes the summary, including the ones that did
nothing — this host is the single point the fleet depends on.

| Line | When |
|------|------|
| `checked <n> node(s): <n> fresh, <n> armed, <n> with work on them, <n> not answering, <n> filtered out` | The summary. Grows a clause for nodes waiting out `ARM_RETRY_MINUTES`, for jobs past `MAX_JOB_HOURS`, and for nodes over the arm limit |
| `ARM <n> node(s) whose heartbeat is older than <n>m: <nodelist>` | One fan-out going out. The nodelist is compressed for pasting |
| `ARM FAILED <node>: <what it said>` | That node's half of the fan-out output. `arm.log` keeps the full text per attempt |
| `EXIT: 'sinfo -N -h' returned nothing` | No answer is not an answer: a busy controller looks identical to an empty cluster, so nothing is armed — see [explanation/sequencing.md#when-the-controller-does-not-answer](../explanation/sequencing.md#when-the-controller-does-not-answer) |
| `EXIT: <host> refreshed the watchdog claim <n>s ago … stands by` | Another host is arming the fleet. Two hosts reading as head is worth settling with `SUPERVISOR_HOST` |
| `OPEN submission circuit for <n>m: <n> matching failures in <n>m -- <diagnostic>` | The watchdog observed a widespread submission failure and wrote the shared bounded hold |
| `took the watchdog claim from <host>` | The previous watchdog stopped refreshing and this host took over past the lease |
| `EXIT: SUPERVISOR_HOST=<host> … and this is <host>` | Pinned elsewhere by the site |
| `RUN_ARMING=<value> in <settings file> -- <n> node(s) left unarmed` | No node is armed. Agents already running are untouched and keep cycling, and this cycle still wrote their views |
| `snapshot: <n> of <n> node view(s) written` | The fleet's one look at Slurm, landed. Every node decides from this — see [explanation/the-fleet-snapshot.md](../explanation/the-fleet-snapshot.md) |
| `WARNING: no node survived EXCLUDE_NODES=… and NODE_FILTER=… -- no view was written` | Every agent will stop deciding once the view it has ages out |
| `CANCELLED pending under RUN_JOBS=<value>: <ids>` | The pause reaching the queue, fleet-wide in one call |
| `RUN_JOBS=no: job <id> (<name>) still RUNNING -- left to finish` | A pause stops new work; it does not kill work in progress |
| `CANCELLED held after a failed launch ('launch failed requeued held'): <ids>` | Jobs the scheduler gave up launching, which sit at priority 0 and never start — see [explanation/sequencing.md#jobs-the-scheduler-has-given-up-on](../explanation/sequencing.md#jobs-the-scheduler-has-given-up-on) |
| `YIELDED <node>: cancelled our job <id> (<name>) to get out of the way of job <id> (<name>, <user>) pending <n>m` | The head-node watchdog found somebody else queued for the node and cancelled our running job for them. The compute node did not initiate the cancel |
| `not a waiter: job <id> (<name>, <user>) pending <n>m cannot start -- <u> of the <n> node(s) it needs are schedulable -- <node> (<state>)…` | A pending job whose nodes are drained, down, or held by somebody this cannot cancel. Yielding to it would give the nodes to nobody — see [explanation/sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter](../explanation/sequencing.md#a-waiter-that-cannot-run-is-not-a-waiter) |
| `no node states passed to the scan -- a waiter whose nodes are drained cannot be told from one that would start` | The check above is inert this cycle; every waiter reads as able to run |
| `not yielded, nothing of ours confirmed running there: <node> (<waiter>)…` | A node somebody is queued for that this did not give up. Says so, rather than leaving it indistinguishable from the scan never running |
| `WARNING: scancel <id> said '<output>' -- <node> was not given up` | The kill was refused; `scancel` reports that on stdout while exiting `0`, so the output is the report |
| `EXIT: <neither clush nor pdsh is installed here>` | Nothing was armed and no attempt was recorded, so nothing is spent against `ARM_MAX_ATTEMPTS` |
| `DRAIN <node>: job timeout after <n>h (RUNNING, job <id>)` | `MAX_JOB_HOURS`, issued from here because the node's own cycle stops at the busy gate. Carries no `DRAIN_MARKER`, so nothing clears it automatically |
| `drain suppressed by DRAIN_AFTER_FAILED_BENCHMARK=<value>: <node> -- <reason>` | The same finding with drains off. What it would have done is still written down |
| `WOULD ARM …` / `WOULD DRAIN …` / `WOULD CANCEL …` / `WOULD YIELD …` | `--explain`. It reads the queue and the markers and changes nothing — but it does still write the node views, which are what the controller said rather than an action taken on it |

## The container copy trace

`results/<node>/copy.log`, plus the copy's own transient unit —
`journalctl --user -u bringup-copy.service` on the node is what it is doing right
now. Every precondition ends the run and says so; a continuously disabled state
is recorded once per boot rather than rewritten on every two-minute cycle,
because "the images never arrived" and "the images are not built yet" are the
same silence from outside. A cycle with nothing to do writes nothing here — the
copy is the one step whose steady state is genuinely no-op, and a line per node
per cycle saying so would bury the ones that matter.

`RUN_CONTAINER_COPY` is still read from `SETTINGS` on every cycle. The node-local
`${XDG_RUNTIME_DIR}/.bringup-file-copy.disabled-state-logged` file is only a
record that the current disabled period has already been written to `copy.log`;
it does **not** keep copying disabled. Setting `RUN_CONTAINER_COPY=yes` takes
effect on the next cycle and removes that file. Setting it to `no` again writes
one new disabled line. A reboot normally clears `XDG_RUNTIME_DIR`, so a node that
is still disabled writes one new line after it comes back.

| Line | When |
|------|------|
| `EXIT: no *.sqsh in <dir> -- nothing to copy yet` | The normal state until `build_containers.sh` has run |
| `EXIT: <dir> does not exist here (CONTAINER_DIR from …)` | The share is not mounted on this node, or `CONTAINER_DIR` names somewhere that is not there |
| `EXIT: RUN_CONTAINER_COPY=<value> in <settings file>` | `SETTINGS` currently disables new copies; one already running finishes. This appears once per continuous disabled period, not every cycle |
| `EXIT: cannot open /tmp/.file_copy.lock … Fix: sudo rm -f …` | A lock left by the root cycles. `/tmp` is sticky, so it can be neither written nor removed by this account — run the command in the line. See [explanation/containers.md#a-lock-left-by-the-old-chain](../explanation/containers.md#a-lock-left-by-the-old-chain) |
| `EXIT: rsync is not installed here` | Jobs read the image over the share instead, which works and is slower |
| `copying: <n> of <n> image(s) here, from <dir>` | A copy just started, detached. The next line comes when it finishes, which may be several cycles later |
| `copied: <n> of <n> image(s) now in <dir>` | Done. `<dir>` is `NODE_CONTAINER_DIR`; `<n> of <n>` is the fact that matters — a job starts off local disk only when the count is complete |
| `COPY FAILED (rsync exit <n>): <what rsync said>` | With the counts, so a partial copy is distinguishable from none |
| `neither systemd-run nor setsid is available -- copying inline` | The copy holds the cycle rather than running as its own unit |

The counts come from globbing both directories rather than from rsync's own
output: "rsync ran" and "the images are here" are different facts, and only the
second lets a job start off local disk.

`actions/file_copy.sh --explain` writes no trace. It prints the source and
destination followed by rsync's itemized dry-run output, or `up to date` when
there would be no changes. `agent/node-agent.sh --explain` includes that same
preview when it reaches the copy step. Explain mode does not stop at
`RUN_CONTAINER_COPY=no`: the switch prevents real copies, while a dry run is
the safe way to inspect a fleet before enabling them. It prints that setting
as a non-terminal `NOTE`, followed by the requested preview.

## The health trace

`$HEALTH_LOG_DIR/<node>/health.log`, written by `actions/node_health.sh`. The same three
conventions hold, and the same 1 MB / 2000-line trim. Why it is a separate file:
[explanation/health-cadence.md#every-cycle-says-what-it-decided](../explanation/health-cadence.md#every-cycle-says-what-it-decided).

| Line | When |
|------|------|
| `MANUAL: --force -- cadence gate bypassed` | A human ran it with `-f` |
| `EXIT: RUN_HEALTH_CHECKS=<value> … a queued refresh is held rather than consumed` | Paused. The sentinel survives, so a re-check asked for during a maintenance window happens when it lifts — see [how-to/pause-and-resume.md](../how-to/pause-and-resume.md) |
| `EXIT: the baseline … resolves to this node's own log directory` | The golden baseline points at the directory this run would overwrite. Fatal, and the one health line that means *stop and fix the tree* — see [explanation/health-cadence.md#the-golden-baseline](../explanation/health-cadence.md#the-golden-baseline) |
| `EXIT: no health check set at <dir> …` | `HEALTHCHECKS` names a directory that is not there. Refused rather than run, because zero checks pass trivially |
| `refresh requested by hand -- running the checks now` | The sentinel was set, and this cycle consumed it |
| `no .last-check -- the checks have not run here since this cadence was deployed` | First run under the cadence. One per node, ever |
| `EXIT: last run <n>s ago was <clean\|failed>, and a <clean\|failed> run is re-checked every <n>h -- next due in <n>s` | The ordinary quiet cycle. This is what most cycles write |
| `EXIT: HEALTH_INTERVAL_HOURS=0 … the cadence is off` | Both intervals are `0`, so only `--refresh` re-runs anything — see [settings.md#health-check-cadence](settings.md#health-check-cadence) |
| `last run <n>s ago … past its <n>h interval -- re-checking` | The cadence fired |
| `--explain: would run <n> check(s) from <dir> against <baseline>` | `-n`. Nothing was written and nothing drained |
| `every check matches the baseline` | A clean run. The drain-clearing lines below it, if any, come from `slurm-recovery.sh` — see [explanation/drain-recovery.md](../explanation/drain-recovery.md) |
| `differs from <baseline>: <checks>` | The run found something. The check names are what a drain would carry |
| `EXIT: <node> failed health checks, not draining (DRAIN_AFTER_FAILED_HEALTH_CHECK=no)` | Found something, drains off — the shipped configuration. The finding is in the line above and in `logs/<node>/` |
| `DOWN: <node> -- <checks>` | The node was set `DOWN` with those check names as the reason |
| `RUN_RECOVERY=<value> … passed every check but its drain is left where it is` | A clean run that was not allowed to clear the drain |
| `WARNING: scontrol not found; unable to update <node> in Slurm` | Drains are on and the client tools are missing |

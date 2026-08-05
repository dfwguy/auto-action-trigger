# Every line the trace can write

`launch_job.sh` writes `results/<node>/trigger.log`, one timestamped line per
decision, and appends rather than truncates — it is the record, not a status
file. Reading it across the cluster is `trigger-log.sh`, in
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
  once per run; if `trigger.log` is not writable by whoever is running — the
  common case being an operator running as `cmods` against a log root's cycle
  created — the run turns verbose, says so on stderr with the `chown` to fix it,
  and mirrors everything to stdout. A run that can neither write nor speak is
  the one state this whole mechanism exists to make impossible.

The log is trimmed to its last 2000 lines when it passes 1 MB. It gets a line or
two per monitoring cycle, forever.

## Startup and housekeeping

| Line | When |
|------|------|
| `MANUAL: --force -- hourly gate bypassed[, --all -- passing jobs re-queued too]` | A human ran it. Without this, an hour of off-cadence results reads as the sequencer misbehaving |
| `MANUAL TEST: --test <jobs> -- BENCHMARKS and BURNIN not surveyed this run, no drains, quick-view.txt left alone` | A human ran an ad-hoc job. Replaces the `MANUAL:` line, and is what explains a result in a column the reports do not have — see [how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list](../how-to/run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list) |
| `chown <user> <path>` | `results/` or `results/<node>`, or `trigger.log` / `quick-view.txt`, handed back to `JOB_USER` — see [layout.md#result-path-ownership](layout.md#result-path-ownership) |
| `WARNING: <dir> is owned by <user>, not <JOB_USER>, and we are not root` | The same problem seen from a hand-run, which can diagnose it but not fix it |
| `WARNING: JOB_ENV entry '<pair>' is not NAME=VALUE …  -- dropped` | A rejected `JOB_ENV` entry. The sweep still runs, and the reason it ran without your variable is written next to it — see [settings.md#what-is-rejected](settings.md#what-is-rejected) |
| `EXIT: <tool> not on PATH after 'module load slurm' (PATH=…)` | No Slurm client tools; every check below would have read as a healthy idle node |
| `EXIT: NODE_FILTER='<globs>' … does not match <node> -- no jobs submitted here` | This node is outside the set being tested — see [settings.md#restricting-which-nodes-run-jobs](settings.md#restricting-which-nodes-run-jobs). Written every cycle on purpose: "why is this node not testing" has to be answerable from the node's own trace. Names `--force` when it was passed, so the flag does not look ignored |
| `NODE_FILTER='<globs>' does not match <node>, but --test <jobs> names this node … -- testing anyway` | `--test` opens the filter where `--force` does not. Says the node is outside the swept set, so a result the reports do not cover is explained where it happened |
| `state=<node state> explain=<0\|1>` | The ordinary first line of a working cycle |

## Pause and recovery

| Line | When |
|------|------|
| `EXIT: PAUSE_JOBS=<value> in <settings file>` | Paused: nothing submitted, drained or archived. Drains Slurm set itself are cleared above this gate, under `PAUSE_RECOVERY` |
| `PAUSE_JOBS=<value> ... -- explaining anyway` | `--explain` reads through the pause; it writes nothing either way |
| `recovery paused: PAUSE_RECOVERY=<value>` | Drains left exactly where they are, whatever `RECOVER_SLURM_DRAINS` says |
| `PAUSE_JOBS: cancelled pending <ids>` | Pending jobs of ours cleared, so a pause reaches the queue and not just submission |
| `PAUSE_JOBS: job <id> still RUNNING for <t> -- left to finish` | A running job is not killed; the id is named so an operator can `scancel` it deliberately |
| `--force does not override PAUSE_JOBS: it is a site switch, not a timing gate.` | Appended when a forced run hits the pause |
| `RECOVER …` / `state after recovery=<state>` | A drain Slurm set itself was cleared and the node state re-read — see [explanation/drain-recovery.md](../explanation/drain-recovery.md) |
| `WARNING: <home>/slurm-recovery.sh is missing` | A deployment that predates the file. Named rather than skipped quietly, because its absence is invisible from outside: nodes simply stay drained |

## The queue

| Line | When |
|------|------|
| `EXIT: <node> not known to slurm (sinfo -N -n returned nothing)` | Usually a run on the head node |
| `EXIT: <n> job(s) not ours on <node> -- leaving the node to them` | Somebody else is using the node |
| `queue: bench=<n> burnin=<n> [running=<t>] [<id> <state> <reason>…]` | Every cycle that gets this far. The per-job detail is only rendered for jobs that are not cleanly schedulable, so a healthy cycle keeps this to one line |
| `job <id> held after a failed launch ('<reason>') <n>s ago -- cancelling and resubmitting in <n>s` | A held job seen before its retry interval is up |
| `CANCELLED <id> -- held <n>s after a failed launch` | Cleared; the survey below decides what to resubmit |
| `job <id> is held after a failed launch, but its submit time … did not parse -- left queued` | Cancel it by hand |
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
| `EXIT: MAX_QUEUED_JOBS=<n> reached -- <n> of our jobs are queued or running fleet-wide, so <job> run <n> stays eligible…` | The [fleet-wide cap](../explanation/sequencing.md#the-fleet-wide-cap), closed. Expected on a large fleet, and not a fault |
| `fleet cap open: <n> of <n> jobs of ours queued or running` | The cap, open. The count is what to watch when tuning it |
| `WARNING: MAX_QUEUED_JOBS='<value>' … is not a whole number -- ignored` | A typo in `SETTINGS`. The cycle runs uncapped rather than stopping the fleet |
| `backing off: <job> run <n> after <n> failures: <n>h window, <n>m left[; …]` | `RETRY_BACKOFF` is on and a run has waited out more than the flat window. One line for both lists, once a cycle — see [explanation/sequencing.md#backing-off-a-job-that-keeps-failing](../explanation/sequencing.md#backing-off-a-job-that-keeps-failing) |
| `nothing eligible to submit: everything is passing or inside its own retry window (<n>h[, plus an hour per failure to at most <n>h])` | Nothing to do this cycle. The bracketed half appears only when `RETRY_BACKOFF` is on |
| `WARNING: RETRY_BACKOFF=<value> but RETRY_BACKOFF_MAX_HOURS='<value>' … is not a whole number of hours at or above RETRY_INTERVAL_HOURS` | A typo in `SETTINGS`. The flat window is kept rather than the fleet stopped, as with `MAX_QUEUED_JOBS` |
| `WOULD SUBMIT <job> run <n>[ (existing <STATUS> result kept as .<fail\|prev><N>.txt)]: <command>` | `--explain` only |
| `submitted <job> run <n>: Submitted batch job <id> [(JOB_ENV: …)]` | Work went out |
| `SUBMIT FAILED <job> run <n>: <sbatch output>` | Work did not go out, and `sbatch` says why |

A new gate gets a line here and a line in the table above it. An `exit 0` with
no explanation is a bug even when the behaviour is correct: most cycles
legitimately have nothing to do, so a node that has silently stopped testing
looks exactly like a node that is quietly idle. See
[explanation/architecture.md#silence-is-the-enemy](../explanation/architecture.md#silence-is-the-enemy).

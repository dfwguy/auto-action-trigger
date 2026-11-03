# Why health checks re-run on a cadence

`actions/node_health.sh` is the second of the three steps `node-agent.sh` runs,
so it is entered on every node on every agent cycle — the same as
`launch_job.sh`. For most of this tree's life it did nothing on
almost all of those cycles, and that was deliberate.

## What it used to do

The first thing the script did, after locating its settings, was this:

```bash
if [[ -d $node_health ]]; then
    if [[ ! -f $node_health/refresh ]]; then
        exit 0
    else
        rm $node_health/refresh
    fi
fi
```

`logs/<node>/` exists after the first run ever, so every subsequent cycle was a
bare `exit 0` — for the life of the node, unless a human set the `refresh`
sentinel by hand. Thirty-eight checks that read `dmesg`, `lspci`, `nvidia-smi`
and `mlxlink` are not free, and running them every minute on every node to
re-confirm a BIOS version that changes twice a year was the thing being avoided.

Three problems came out of it, in ascending order of cost.

**A node that fails is exactly the node that never re-checks.** The gate keys on
"has this ever run", not on what it found, so a node drained for `ib-link` on
Tuesday is still carrying Tuesday's reason on Friday whether or not the cable
was reseated on Wednesday. The fix is invisible until someone asks for it.

**A repaired node cannot clear its own drain.** The `slurm_recover_node` call
that clears a `health` drain lives at the bottom of this script, past the
checks. A node that never re-checks never reaches it, so with
`DRAIN_AFTER_FAILED_HEALTH_CHECK=yes` the drain is permanent by construction —
the framework takes nodes out and has no path to put them back.

**Nothing was written down.** Every other gate in this tree traces why it
stopped; see [architecture.md](architecture.md). This one exited silently, and
the only trace of a health cycle was the mtime on `logs/<node>/`. A wedged
trigger, a paused one, and one correctly deciding it had nothing to do all
looked identical from the head node.

## The stamp file

`logs/<node>/.last-check` is one tab-separated line: the epoch the run finished,
and `clean` or `failed`.

The outcome is in the stamp rather than derived from Slurm because with the
shipped `DRAIN_AFTER_FAILED_HEALTH_CHECK=no` a failing node carries no Slurm
reason at all — the run records what it found and leaves the node alone. Reading
the outcome back off the drain would mean the cadence only tightened for sites
that had drains turned on, which is the opposite of what a site running with
drains off needs.

It is written *before* the drain, not after. `scontrol` can fail, the controller
can be busy, and a run whose outcome went unrecorded would repeat on the very
next agent cycle, forever, on the node least able to spare the cycles.

A node with no stamp — one whose `logs/<node>/` predates this cadence — runs
once and then joins the cadence. That is why the gate distinguishes "no stamp"
from "stamp says never re-run": an upgrade must not leave the whole fleet
waiting for a sentinel nobody knows to set.

## Choosing the two intervals

| Setting | Ships as | Applies when |
|---|---|---|
| `HEALTH_INTERVAL_HOURS` | 4 | the last run was `clean` |
| `HEALTH_RETRY_INTERVAL_HOURS` | 1 | the last run was `failed` |

Two intervals rather than one, and no backoff — the opposite of
`RETRY_BACKOFF` on the job side, which exists because re-running a six-hour
`mnubergemm` against a node that will fail it again costs the queue six hours.
A health check costs seconds and contends with nothing, so the argument that
produced backoff there does not apply here. A failing node is the one whose
state is most likely to change under an engineer's hands, and it is the one
worth asking about most often.

Setting either to `0` disables the cadence and restores the old behaviour: the
checks then re-run only when `report_health.sh --refresh` asks. That is the
escape hatch for a site that finds 46 checks an hour too expensive, and it is a
real answer rather than a mistake, so nothing warns about it.

## Asking for a re-check

`report_health.sh --refresh <node|nodelist>` writes the `refresh` sentinel, which
the next agent cycle consumes ahead of the cadence. This used to be its own
script, `node-health-refresh.sh`; it is a mode of `report_health.sh` now because
an operator holding a node name wants to look at the checks and re-run them in
the same breath, and two scripts meant remembering which one took a nodelist and
which took a glob.

Merging them did not merge the argument, though, and that is deliberate. Every
reading mode takes a node glob; `--refresh` writes, and a glob that quietly
expands is how one character queues a full check run on two thousand nodes at
once. So it takes names and nodelists, which have to be meant. The cost is that
`--refresh 'ink50*'` is a natural thing to type and used to fail twice over: the
shell passed the pattern through untouched, and `[[ -d ]]` does not glob, so the
literal string was reported as a node with no health log that would "run fresh
on its next agent cycle". Neither half was true. It is refused by name now, with
the nodeset of the `logs/` directories it would have matched printed ready to
paste — the set spelled out, which is the whole point, without making the
operator spell it.

Taking names rather than a pattern is also what lets a tool that *expands* one
compose with it, `$(nodeset -e @IDLE)` being the case worth knowing: the group
is resolved by something that understands groups, and what arrives is an
explicit list. That is the distinction the rule is really drawing — not "no
convenience", but "the expansion happens somewhere the operator can see it
before it is acted on". `sinfo -h -t idle -o %N` is the same idea where
ClusterShell is not installed. See
[reference/scripts.md#--explain-and---refresh](../reference/scripts.md#--explain-and---refresh).

The same restraint applies to a name that simply has no `logs/<node>`. Nothing
on the head node can tell a node that has never run the checks from a
misspelling, and a sentinel cannot be written for either, so the line says what
was not queued and gives both readings rather than predicting a cycle that may
have nobody to run it.

The sentinel is consumed at exactly one place in `node_health.sh`, below the
`RUN_HEALTH_CHECKS` gate. A refresh queued during a pause is therefore still
waiting when the pause lifts, rather than being eaten by a cycle that then
declined to run anything. See
[pause-and-resume.md](../how-to/pause-and-resume.md).

## The golden baseline

`valid-config/default` is a symlink to a **copy** of one validated node's
`logs/<node>/`, taken by `admin_set-baseline.sh`. The copy is the whole point,
and the cadence is what makes it load-bearing.

Pointed straight at a live `logs/<node>/` — which is a one-line change and looks
equivalent — the baseline used to be merely fragile: the checks ran once, so the
reference stayed whatever it was on the day. On a cadence it becomes something
worse. Every re-check on the baseline node rewrites the files every other node
is judged against, so the reference silently follows that node's drift, the
fleet keeps agreeing with it, and a real regression that lands on the baseline
node first is adopted as the new definition of correct. Nothing fails, and the
reports stay clean.

`node_health.sh` therefore resolves both paths and refuses to run — fatally, not
with a warning — when the baseline is the directory it is about to write:

```
EXIT: the baseline .../valid-config/default/ resolves to this node's own log
directory, so running the checks here would overwrite the thing they are
judged against.
```

Both paths must resolve for the comparison to fire. `readlink -f` prints nothing
when a parent directory is missing, and two empty strings compare equal, which
would take the whole fleet out over a missing `valid-config/`.

`admin_set-baseline.sh` copies only the gated checks, so `refresh`,
`.last-check`, the traces and the agent's `service.log` never reach the
baseline. None is a check, and a file sitting in the baseline directory reads
as a check name to every consumer that lists it — `report_health.sh` filters
them as well, because a baseline taken before this change can still hold one.
The informational checks stay out for a related reason: nothing diffs them, so
a copy in the baseline is an answer nobody asked for. See
[node-inventory.md#it-is-not-a-baseline](node-inventory.md#it-is-not-a-baseline).

## Every cycle says what it decided

The trace goes to `$HEALTH_LOG_DIR/<node>/health.log`, beside the check output,
and
`check_trigger-log.sh` section 5 reads it the same way section 1 reads the sequencer's:
a log that has stopped being written is the agent not firing, and a fresh log
whose last line is an `EXIT` is a gate that has already named itself.

It is a separate file rather than lines in `trigger.log` because the two steps
rotate at different rates — the sequencer writes a line or two per cycle and the
health side writes one per cadence interval — and interleaving them would mean
the sequencer's volume rotating the health trace away long before it was stale.

`report_health.sh --explain` answers the question the trace cannot: not what the
last cycle did, but when the next one is due, read from the stamps across the
whole fleet.

## A check that does not return

Nothing used to bound a check. The runner starts them one after another inside a
cycle that also runs `file_copy` and `launch_job`, under one lock. A tool that
never returned — a wedged GPU driver under `nvidia-smi`, a stuck `mlxlink` —
stopped the loop where it stood. The checks after it did not run, no stamp was
written, no drain was made and no trace line said why. Only systemd's
`TimeoutStartSec=900` ended the cycle, and `launch_job` could not run on that
node meanwhile. `health.log` went stale, which `check_trigger-log.sh` reads as
"the agent is not firing": the opposite of what was happening.

Each check now has a time limit, `HEALTH_CHECK_TIMEOUT_SECONDS` (`90`), which one
check can override with `# timeout: N`. The limit is a setting because the right
number depends on hardware nobody had timed when it was chosen. The `timing:`
line gives the data to change it. A check that hits the limit is killed, and its
log holds one line, `check timed out -- no result`. Three decisions follow.

- **A timeout is a finding, not a pass and not a skip.** The log differs from
  the baseline, so the check's name goes in the reason and the node drains if
  drains are on. Recording nothing would pass every check whose healthy output is
  empty, and a node that cannot answer `nvidia-smi` in a minute and a half is not
  one to hand work to. An informational check records the timeout and never
  drains. If the limit is too tight for healthy hardware, the fix is to raise it,
  and drains being off by default means that mistake costs a trace line, not a
  node.
- **The output goes to a file, not into `$(...)`.** A child of the check that
  survives the kill, because it ignores `TERM` or is stuck in the kernel, keeps
  the pipe open, and a command substitution waits for it. With a 3-second limit
  the runner still returned after the child's 20 seconds; writing to a temp file
  returned after 3.
- **The baseline refuses it.** A baseline taken during a wedge would pass every
  node that wedges the same way, so `admin_set-baseline.sh` will not promote a log
  holding the timeout line.

What the limit does not reach. A child that ignores `TERM`, or sits in an
uninterruptible state, is orphaned rather than killed: it stays until it
finishes, so a node that hangs the same tool every cycle collects one per cycle.
There is no limit on the whole run, so many checks each using their full limit
could still reach systemd's 900 seconds. And a `timeout` placed in front of one
tool inside a check does not belong in a pipeline such as `tool | grep || true`,
where a killed tool reads as empty output, which is what a healthy node prints
for several checks. A check that bounds one of its own tools has to handle the
exit status, as `44-bmc-firmware` does.

## A due time assumes a live node

Everything above is a prediction about a node that is still running cycles, and
both `--explain` and `--refresh` are read on the head node from files the *node*
writes. Neither contacts anything. So a node whose agent has stopped produces
the most misleading output either one can produce: a stamp that still parses, a
due time that arrives and passes, and a `refresh` sentinel that is queued
successfully and sits there for ever, because the only code that consumes it
runs on the node that is not running.

That is what `overdue by 28h` means and what it does not. It reads as a cadence
problem and is almost always an agent problem — the interval elapsed and nothing
was there to notice. So both modes ask `heartbeat_stale` first, and a node that
has written no heartbeat in `HEARTBEAT_STALE_MINUTES` is reported as **not
cycling** rather than being given a time nothing will act on. `--refresh` still
writes the sentinel, since it is valid the moment the node comes back, and says
in the same breath that nothing will pick it up yet.

The heartbeat is the right question because the agent touches it every cycle
before any gate, so it separates "the checks decided not to run" from "nothing
ran". `./check_trigger-log.sh` section 0 is where a stale one gets diagnosed; this is
the same judgement `check_next-run.sh` prints as `not cycling`, from the same helper in
`settings.sh`. See
[the-agent-and-the-watchdog.md#what-the-heartbeat-means](the-agent-and-the-watchdog.md#what-the-heartbeat-means).

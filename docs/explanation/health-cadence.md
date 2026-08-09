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
checks then re-run only when `health-check.sh --refresh` asks. That is the
escape hatch for a site that finds 38 checks an hour too expensive, and it is a
real answer rather than a mistake, so nothing warns about it.

## Asking for a re-check

`health-check.sh --refresh <node|nodelist>` writes the `refresh` sentinel, which
the next agent cycle consumes ahead of the cadence. This used to be its own
script, `node-health-refresh.sh`; it is a mode of `health-check.sh` now because
an operator holding a node name wants to look at the checks and re-run them in
the same breath, and two scripts meant remembering which one took a nodelist and
which took a glob.

The sentinel is consumed at exactly one place in `node_health.sh`, below the
`PAUSE_HEALTH_CHECKS` gate. A refresh queued during a pause is therefore still
waiting when the pause lifts, rather than being eaten by a cycle that then
declined to run anything. See
[pause-and-resume.md](../how-to/pause-and-resume.md).

## The golden baseline

`valid-config/default` is a symlink to a **copy** of one validated node's
`logs/<node>/`, taken by `set-valid-default.sh`. The copy is the whole point,
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

`set-valid-default.sh` also strips `refresh` and `.last-check` out of the copy.
Neither is a check, and a `.last-check` sitting in the baseline directory reads
as a check name to every consumer that lists it —
`health-check.sh` filters it as well, because a baseline taken before this
change still has one.

## Every cycle says what it decided

The trace goes to `results/<node>/health.log`, beside `trigger.log`, and
`trigger-log.sh` section 5 reads it the same way section 1 reads the sequencer's:
a log that has stopped being written is the agent not firing, and a fresh log
whose last line is an `EXIT` is a gate that has already named itself.

It is a separate file rather than lines in `trigger.log` because the two steps
rotate at different rates — the sequencer writes a line or two per cycle and the
health side writes one per cadence interval — and interleaving them would mean
the sequencer's volume rotating the health trace away long before it was stale.

`health-check.sh --explain` answers the question the trace cannot: not what the
last cycle did, but when the next one is due, read from the stamps across the
whole fleet.

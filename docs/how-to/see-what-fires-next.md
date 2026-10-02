# See what fires next

`check_trigger-log.sh` answers "why did nothing happen?" from what the chain already
wrote. `check_next-run.sh` answers the other half — "when will something happen?" —
by doing the cadence arithmetic the gates on each node are about to do, over
the same files, and grouping the fleet by the answer.

Read-only. It submits nothing, drains nothing and writes nothing.

```bash
bash check_next-run.sh                    # both sections, whole fleet
bash check_next-run.sh --tests            # benchmark submissions only
bash check_next-run.sh --healthchecks     # health checks only
bash check_next-run.sh -t ink50-dh01      # one rack, benchmarks only
```

The node pattern takes the same rules as `report_job-status.sh`: a bare string
matches by prefix, a glob is honoured as written.

## What it prints

One block per bucket, soonest first, each block a compressed node list over the
one line every node in it shares:

```
TESTS — when each node next submits a benchmark

---------------
ink50-dh01-h02-[11-14]
---------------
soon — dcgmi-r1
---------------
ink50-dh01-h02-[15-18]
---------------
within 4h — nvbandwidth
---------------
ink50-dh01-h03-[11-18]
---------------
nothing due — every benchmark passes here
```

The grouping is `clubak`, or `dshbak` where only `pdsh` is installed. With
neither on PATH it prints one line per node and says so on stderr — see
[reference/scripts.md#grouping-identical-rows](../reference/scripts.md#grouping-identical-rows).

## How the buckets are chosen

A node's bucket is the *earliest* thing it will do, not a list of everything it
owes. For the benchmark section that is the soonest-eligible column across
`BENCHMARKS` — and `BURNIN` when `RUN_BURNIN` is on — judged exactly as
`actions/launch_job.sh` judges it:

| The node's state | Bucket |
|---|---|
| No result file for a column | eligible now |
| A result that does not pass | eligible at its mtime plus `RETRY_INTERVAL_HOURS`, widened an hour per `.failN` archive beside it up to `RETRY_BACKOFF_MAX_HOURS` |
| Every column passes | `nothing due` |

The health section reads `logs/<node>/.last-check`, whose second field picks the
interval: `HEALTH_RETRY_INTERVAL_HOURS` after a run that found something,
`HEALTH_INTERVAL_HOURS` after one that did not. A queued `refresh` sentinel and
a node that has never run the checks are both due now; `HEALTH_INTERVAL_HOURS=0`
is `nothing due`, because only `report_health.sh --refresh` re-runs them then.

`soon` is anything already due or due inside one agent tick — the calendar
interval plus its spread, so `AGENT_INTERVAL_MINUTES` × 1.5. Everything else
rounds *up* to the hour, so `within 2h` means "more than one hour away, less
than two". A bucket is the rounded hour and not the exact second, which is what
lets a rack that was armed together print as one line.

## The three answers that are not times

| Group | What it means |
|---|---|
| `not cycling` | The heartbeat is stale. No gate on that node is being reached at all, so nothing below it fires and no time would mean anything. Take this one first — `check_trigger-log.sh` section 0 and `results/<node>/arm.log` are the next reads |
| `waiting` | A job of ours is out under `results/<node>/.in-flight`. One job at a time per node, so nothing more is submitted until it finishes — see [explanation/sequencing.md#one-job-at-a-time](../explanation/sequencing.md#one-job-at-a-time) |
| `nothing due` | Every benchmark passes, or the health cadence is switched off. Not a fault |

## When the times are hypothetical

`RUN_JOBS=no` and `RUN_HEALTH_CHECKS=no` stop the work without stopping
the clock, so the buckets become when each node *would* have fired. Both say so
on stderr rather than in the report, so a paused fleet cannot be read as a
running one — and so the note cannot land inside a node list being pasted
somewhere else.

## What it does not tell you

Whether the job that fires will *start*. That is the queue's answer, not the
node's: see
[estimate-when-a-job-will-start.md](estimate-when-a-job-will-start.md).

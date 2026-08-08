# Pause the framework, and empty the queue

Four switches in `SETTINGS` stop the framework doing anything, without
unregistering it from BCM. Edit them on the head node; every node reads the same
NFS-exported file, so a pause takes effect fleet-wide on the next monitoring
cycle.

```bash
PAUSE_JOBS=yes             # no benchmarks submitted; queued ones cancelled
PAUSE_HEALTH_CHECKS=yes    # no health checks run; Slurm untouched
PAUSE_CONTAINER_COPY=yes   # no new rsync into /tmp/containers
PAUSE_RECOVERY=yes         # no drain Slurm set itself is cleared
```

The switches are separate because they stop different things: pausing the
benchmarks during a maintenance window usually should *not* stop health checks
from telling you what state the nodes came back in. Why each behaves as it does
is in
[explanation/sequencing.md#what-a-pause-is-for](../explanation/sequencing.md#what-a-pause-is-for).

## What a pause leaves running

In order of how long it takes to stop:

- **Pending benchmarks are cancelled on the first paused cycle.** They wrote
  nothing, and the sweep re-queues them when the pause lifts.
- **One benchmark per node may still be running**, and is left to finish — up to
  `MAX_JOB_HOURS`, so up to ~6.5 hours if it is a burn-in run. Its job id is in
  that node's `trigger.log`.
- **A detached `rsync` from an earlier cycle finishes.** It reads NFS into a
  local cache, holds no node and blocks no job.
- **Our own drains stay.** `PAUSE_JOBS` drains nothing and clears nothing
  carrying `DRAIN_MARKER`, so a node the sequencer drained before the pause
  stays drained, marker and all, and is picked up again when the pause lifts.
  Resume by hand if you need it back sooner.
- **Drains Slurm set itself are still cleared**, unless `PAUSE_RECOVERY=yes`.

Nothing is lost. Results stay on disk and the sweep resumes rather than
restarting, and a `refresh` set by `health-check.sh --refresh` is held through the
pause rather than consumed by a run that does nothing.

`launch_job.sh --explain` still works while paused, and is the way to see what a
sweep *would* do on a node before lifting one.

## Confirming the pause is why the cluster is quiet

```bash
bash trigger-log.sh                 # every node's last decision: PAUSE_JOBS=yes ...
bash trigger-debug.sh               # reports the switches in section 0, before the links
```

Both `status-check.sh` and `health-check.sh` print a banner while their half is
paused, because a report that cannot change looks exactly like a cluster that
has settled.

## Emptying the queue now

`PAUSE_JOBS` stops the *next* submission and cancels what is pending; the
benchmark already running on each node is left to finish. When the cluster has
to be empty now — a maintenance window starting, a switch coming out, another
team needing the nodes — `kill-jobs.sh` is the hard stop:

```bash
bash kill-jobs.sh                      # cancel every job of ours, fleet-wide
bash kill-jobs.sh -p                   # ... and set PAUSE_JOBS=yes so it stays empty
bash kill-jobs.sh ink50-dh01-i01       # one node (prefix match, as elsewhere)
bash kill-jobs.sh 'dh01-rack0[12]*'    # a glob, honored as written
bash kill-jobs.sh -n 'dh01-rack0[12]*' # what that would have cancelled, and nothing else
```

`-n` reads the queue and prints the list without cancelling or writing
`SETTINGS`, `-p` included. It is worth the extra command on anything fleet-wide:
the patterns are shell globs typed under time pressure, and a `*` in the wrong
place is the difference between one rack and the cluster.

It selects on the job *name*, `bringup-<node>` and `burnin-<node>`, so it is
narrower than `scancel -u cmods`: anything else the framework's account happens
to own — a hand-submitted reproduction, another team's job on a shared account —
is not matched. The patterns filter on the node half of that name, with
`status-check.sh`'s rule: a bare string is a prefix, anything holding a glob
character is used as written.

**Cancelling alone is a stall, not a stop.** The sequencer's next cycle finds an
idle node and submits the next benchmark, so a bare run buys roughly one
monitoring cycle. `-p` is what makes it hold, and it writes `PAUSE_JOBS=yes` to
`SETTINGS` *before* cancelling anything — the other order leaves a window for a
cycle to resubmit into. A run without `-p` says so on the way out.

The pause is fleet-wide even when the patterns are not, because `SETTINGS` is
one file read by every node; the run prints a note when both are given. If the
site has no `SETTINGS`, it is created from `SETTINGS.default` — never edited in
place, since a tarball drop overwrites it. **Nothing here lifts a pause**: set
`PAUSE_JOBS=no` by hand when the window closes.

The script needs Slurm and nothing else, and finds the tree only for `-p` —
first beside itself, then at `BRINGUP_HOME` (default `/home/cmods/bringup`). So
a copy pasted into any directory still cancels correctly, and one that cannot
find a tree cancels anyway, reports why the pause did not happen, and exits
non-zero.

To do it by hand instead:

```bash
squeue -h -n bringup-<node> -o '%i %T'   # the sweep, on one node
squeue -h -n burnin-<node>  -o '%i %T'   # its burn-in
scancel -n burnin-<node>                 # stop just the burn-in, keep testing
scancel -u cmods                         # every job the framework owns
```

Cancelling jobs owned by `JOB_USER` needs that account or root. `scancel`
reports a refused kill on stdout and can still exit `0`, so `kill-jobs.sh`
treats its output as the report rather than its exit status, and prints the
`squeue` that confirms the queue is actually empty.

## What the cancelled jobs leave behind

Nothing that needs cleanup:

- A **part-written result file**, which the gates read as `INCOMPLETE`. The
  sweep retries that benchmark once the pause lifts. That is the cost of a hard
  stop; it is not a failure of the node.
- The node's **`.in-flight` marker**, cleared by the sequencer itself. That gate
  runs *above* `PAUSE_JOBS`, so it resolves during the pause rather than after
  it: the job is gone from the queue, the partial result is archived, and the
  slot is freed. See
  [explanation/sequencing.md#when-a-marker-goes-stale](../explanation/sequencing.md#when-a-marker-goes-stale).

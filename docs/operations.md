# Operator reference

Everything here runs from the headnode and is safe to run while the triggers are
live. For the common day-to-day commands see the
[Operating a bringup](../README.md#operating-a-bringup) section of the README —
this page is the full set.

## Status and reporting

```bash
bash status-check.sh                      # every node
bash status-check.sh ink50-dh01-h20        # one rack (bare prefix)
```

Reads `results/` and prints per-node status (`NOT_RUN`, `IN_PROGRESS`, `DONE`,
`FAIL`) for each benchmark column, grouped by identical status via `dshbak`.

```bash
bash status-daily-report.sh
```

Writes `reports/report-YYYY-MM-DD_HH-MM-SS.csv` with one row per node. Completed
jobs show extracted performance metrics (Gflops for HPL, busbw GB/s for
allreduce/alltoall) instead of a status string.

```bash
bash watch-rack.sh "rack01-node[1-32]"
```

Refreshes every 20 seconds, showing only nodes that are DOWN or drained.

## Health checks

```bash
bash node-health-refresh.sh node001
bash node-health-refresh.sh "node00[1-18]"
```

Sets the `refresh` sentinel so the next monitoring cycle re-runs
`node_health.sh` on those nodes.

```bash
bash sync-check.sh node001
```

Diffs the node's health check output against the valid-config baseline for each
check listed in the Slurm drain reason — the fastest way to see why
`node_health.sh` took a node down.

```bash
bash set-valid-default.sh node001
```

Captures a validated node's `logs/` as the new baseline. See
[health-checks.md](health-checks.md).

## Node state

```bash
sinfo -n node001 -o '%T %E'          # state and reason
scontrol show node node001           # full detail
sinfo -R                             # every drained node with reasons
```

If the reason contains `auto-retry`, the sequencer put it there and will clear
it itself on the next retry pass — resuming by hand just starts the next sweep
sooner. Any other reason is an operator drain, and the sequencer will neither
clear it nor queue work behind it.

```bash
scontrol update nodename=node001 state=RESUME              # clears drain + reason
scontrol update nodename="node[001-018]" state=RESUME      # a whole rack
```

`RESUME` is what you want in almost every case — it clears the drain reason and
lets Slurm put the node back to `idle` or `alloc` on its own. Setting
`state=IDLE` directly is rejected from some states and skips that bookkeeping.
These commands need privilege — see
[Slurm permissions](sequencer.md#slurm-permissions).

## Disabling drains (`NODRAIN`)

A file named `NODRAIN` in the bringup root disables every drain the sequencer
would issue, including the `MAX_JOB_HOURS` timeout drain:

```bash
touch /home/cmods/bringup/NODRAIN     # stop draining on failure
rm /home/cmods/bringup/NODRAIN        # resume normal behaviour
```

Nothing else changes — benchmarks still run, results are still recorded, and
failures still re-queue hourly. The node is simply never taken out of service,
so failures show up in `status-check.sh` and the CSV report rather than in
`sinfo`.

Useful during early bringup when you want the full picture across a rack before
nodes start dropping out, or while debugging a benchmark that is failing for
reasons unrelated to the hardware.

**This repo ships with `NODRAIN` present**, so drains are off out of the box.
Delete it once you want failures to pull nodes from the pool. It does not clear
drains that already exist.

## Debugging the trigger chain

```bash
bash trigger-debug.sh                 # whole cluster
bash trigger-debug.sh ink50-dh01-h20  # one rack
```

Walks the chain from BCM down to `sbatch` and names the broken link: action
registered, trigger enabled *and* with its action actually bound, script
present, the last decision each node's sequencer made, and result-path
ownership. Read-only.

To ask a single node directly instead of waiting for a monitoring cycle:

```bash
pdsh -w ink50-dh01-h20-11 '/home/cmods/bringup/actions/launch_job.sh --explain'
```

`--explain` prints every gate the sequencer evaluates and the `sbatch` commands
it would issue, as a dry run — nothing is submitted, drained, or archived, so it
is safe while the trigger is live.

Each node also keeps a running trace at `results/<node>/trigger.log`, one line
per monitoring cycle recording what it did or why it stopped.

## Resetting results

```bash
bash single-node-purge.sh node001 "node[002-004]"   # one or more nodes/nodelists
mv results results.$(date +%F)       # everything, kept
rm -rf results                       # everything, gone
```

Safe at any time — the tree is recreated and re-owned on the next monitoring
cycle. See [result-path ownership](sequencer.md#result-path-ownership) for why
ownership matters and how to fix a tree immediately.

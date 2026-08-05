# Turn drains on, and read what drained

Two settings decide whether a failure takes a node out of service. Both live in
`SETTINGS` (or `SETTINGS.default` when a site has not made a `SETTINGS`), and
both ship **off**.

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # node_health.sh: mismatch against baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # launch_job.sh: failed sweep, and MAX_JOB_HOURS
```

## Running with drains off

Nothing else changes with either off — checks and benchmarks still run, results
are still recorded, and failures still re-queue hourly. The node is simply never
taken out of service, so failures show up in `status-check.sh`, `sync-check.sh`
and `daily-report.sh` rather than in `sinfo`.

That is the state to be in during early bringup, when you want the full picture
across a rack before nodes start dropping out, and while debugging a benchmark
that is failing for reasons unrelated to the hardware.

Two consequences worth knowing:

- With `DRAIN_AFTER_FAILED_HEALTH_CHECK=no`, `health-check.sh` reads the Slurm
  reason field and therefore reports every node as passing. It prints a banner
  saying so. Use `sync-check.sh <node>`, which diffs the logs directly, until
  drains are on.
- Turning either on does not clear drains that already exist, and does not drain
  a node that is already failing — the next monitoring cycle does that.

## Which to turn on first

`DRAIN_AFTER_FAILED_BENCHMARK` first, and `DRAIN_AFTER_FAILED_HEALTH_CHECK`
last. A health check drains on *any* diff against `valid-config/default`, so a
baseline taken from a node that is itself slightly off, or one check that is
per-rack rather than per-cluster, drains the entire cluster on the first
monitoring cycle. Bring it up only once this reads clean across the fleet:

```bash
bash health-check.sh --summary
```

These replace the old `NODRAIN` file, which is gone. A `NODRAIN` left over from
an earlier deployment now does nothing; delete it.

## Which drains will clear themselves

Some of the drains in `sinfo -R` will go away without anyone touching them, and
knowing which is the difference between waiting a cycle and resuming a node by
hand. `slurm-recovery.sh` runs inside both actions and sorts every drain reason
into one of four classes:

| Class | The reason says | Who clears it |
|-------|-----------------|---------------|
| `marker` | it carries `DRAIN_MARKER` — this framework drained the node over a benchmark | `launch_job.sh`, once the benchmarks pass |
| `health` | it is a list of check names — `node_health.sh` drained the node | `node_health.sh`, on a clean run |
| `machine` | it matches `RECOVER_REASONS` (prolog, epilog, rogue process, failed launch, reboot or power-off, duplicate jobid, GRES or CPU count mismatch), or it is empty | the recovery, subject to its own gates |
| `operator` | anything else | nobody, ever |

**Operator drains are never cleared by anything in this tree.** A node somebody
took out of service and a node Slurm drained over a lost epilog race look the
same in `sinfo`, and resuming the first one puts work back on a machine somebody
is standing in front of — invisibly, because the node returns to `idle` with the
reason gone and nothing left to say it was ever drained on purpose.

Free-text prose in the reason (`waiting on RMA`, `bad NVLink, do not use`) is
what keeps a drain out of the `machine` class. A drain set from a named admin
account is left alone whatever its text says, and so are `maint`, `reserved`,
`planned` and `fail`. The full classification, its three discriminators and its
one stated limit are in
[explanation/drain-recovery.md](../explanation/drain-recovery.md);
`tests/recover-test.sh` holds a case for each of them.

A `machine` drain is still only cleared once the condition behind it is gone —
the node finished booting, `slurmd` answering, no compute processes left holding
the GPUs, no job still assigned. Past `RECOVER_MAX_ATTEMPTS` inside
`RECOVER_WINDOW_HOURS` the drain is left exactly as Slurm set it.

## Reading what the recovery did

```bash
grep RECOVER results/*/trigger.log | tail            # what came back, and why
cat results/<node>/recover.log                       # one line per recovery
./trigger-log.sh                                     # recoveries appear as events
```

Every decision, including the ones that changed nothing, is written to
`results/<node>/recover.log` and traced — so a node that is not coming back says
why, in the same place everything else does.

`launch_job.sh --explain` classifies and reports without resuming anything, and
reads through `PAUSE_RECOVERY`:

```bash
pdsh -w ink50-dh01-h03-16 '/home/cmods/bringup/actions/launch_job.sh --explain'
```

## Resuming by hand

```bash
scontrol update nodename=node001 state=RESUME              # clears drain + reason
scontrol update nodename="node[001-018]" state=RESUME      # a whole rack
```

Needs privilege — see
[reference/layout.md#slurm-permissions](../reference/layout.md#slurm-permissions).
If the reason contains `auto-retry`, resuming by hand only starts the next sweep
sooner; the sequencer would have cleared it itself.

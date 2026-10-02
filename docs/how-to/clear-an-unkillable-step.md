# Clearing a step that outlived its own kill

A job's processes ignored `SIGKILL`, Slurm gave up and drained the node, and the
processes are still on the GPUs. The node cannot come back on its own and
nothing in this tree will resume it — see
[explanation/drain-recovery.md#a-step-that-outlives-its-own-kill](../explanation/drain-recovery.md#a-step-that-outlives-its-own-kill)
for why.

## Recognising it

Either of these, and they are the same incident:

```bash
sinfo -R | grep -i 'kill task failed'          # Slurm's own words
grep 'recover held' results/<node>/trigger.log | tail -3
```

A held line repeating every cycle with **the same pids** is the tell. Pids that
change between cycles are a node doing normal work, not a wedge:

```
recover held: <node> is draining ('Kill task failed (JobId=132603 StepId=2)',
machine) but compute processes still on the GPUs (pids 1847765 1847634 …)
```

The held line carries its own countdown — `unchanged for 2400s of 3600s before
this counts as a step that outlived its own kill` — and then names what it
found, whether or not this site lets it act. With `RECOVER_DOWN_UNKILLABLE=yes`
the hand-off below happens without you; with it `no`, the shipped default, the
line points you here and the node stays exactly as Slurm left it.

## Confirm it before doing anything

```bash
clush -w <node> 'ps -o pid,stat,etime,comm -p <pids>'
pdsh -R ssh -w <node> 'ps -o pid,stat,etime,comm -p <pids>'
squeue -j <jobid> -O JobID,TimeUsed,TimeLimit,EndTime
```

Two answers decide what this is:

| `ps` says | Means |
|---|---|
| `R` or `Rl`, elapsed far past the job's limit | Spinning inside a GPU kernel. `SIGKILL` is pending and will never be delivered. Reboot |
| `D` | Blocked in the driver. Reboot |
| Nothing — the pids are gone | It cleared on its own; the next cycle resumes the node |

If `TimeUsed` is still under `TimeLimit`, this is a live job and not a wedge.
Leave it alone. A step kill can fail on one step while the job legitimately
carries on with the next.

`kill -9` is not the next step. Slurm already sent exactly that, and the drain
reason is the record of it failing.

## Capture the evidence first

A reboot destroys it, and for an NVLink fault this is what the RMA rests on.
These are health checks 10, 11 and 36 run by hand:

```bash
clush -w <node> 'nvidia-smi nvlink -s;
    nvidia-smi nvlink -e | grep BER | grep -v 15e-255;
    nvidia-smi --format=csv --query-gpu gpu_bus_id,fabric.state,fabric.status;
    sudo -n dmesg | grep -E "NVRM: knvlink|Xid" | tail -40' | tee /tmp/<node>-nvlink.txt

pdsh -R ssh -w <node> 'nvidia-smi nvlink -s;
    nvidia-smi nvlink -e | grep BER | grep -v 15e-255;
    nvidia-smi --format=csv --query-gpu gpu_bus_id,fabric.state,fabric.status;
    sudo -n dmesg | grep -E "NVRM: knvlink|Xid" | tail -40' | tee /tmp/<node>-nvlink.txt
```

Fewer than 72 links up, or a `fabric.state` that is not `COMPLETED`, is the
NVLink answer.

## Take it out of service

`DOWN`, not `DRAIN`. A drained node keeps its allocation, which is the state it
is already stuck in; `DOWN` makes slurmctld stop waiting for a confirmation
slurmd will never send and release the job.

```bash
scontrol update nodename=<node> state=DOWN \
  reason="unkillable job: NVLink down, ranks survived their step kill - pending reboot"
```

**On a multi-node allocation this releases everybody's ranks**, not just the
wedged node's. Check what else is in the job before you do it:

```bash
squeue -j <jobid> -o '%i %D %N'
```

Two things about the reason text, both load-bearing:

- Free-text prose keeps it in the `operator` class, which nothing in this tree
  ever clears. Quote `Kill task failed` into it and it classifies as `machine`
  and gets resumed on the next cycle.
- Set it as yourself, not as `root`. `RECOVER_SETTERS="slurm root"` means a
  `root` drain is still judged on its text alone; your own account is judged on
  the account. Either is enough on its own — do both.

## Power-cycle, then return it

`scontrol reboot ASAP` waits for the node to drain, which will never happen, so
this is an out-of-band power cycle. A GPU reset will not take while processes
hold the devices.

When it is back, let the checks judge it before it takes work again — a node
that comes back with NVLink still short should not be resumed:

```bash
clush -w <node> '/cluster/bringup/actions/node_health.sh'
pdsh -R ssh -w <node> '/cluster/bringup/actions/node_health.sh'
./report_health.sh --diff <node>
scontrol update nodename=<node> state=RESUME
```

A `DOWN` node needs an explicit `RESUME`; nothing does it for you, deliberately.

## Turning the automatic hand-off on

Three settings, in `SETTINGS` —
[reference/settings.md#steps-that-outlive-their-own-kill](../reference/settings.md#steps-that-outlive-their-own-kill):

```bash
RECOVER_DOWN_UNKILLABLE=yes
RECOVER_UNKILLABLE_AFTER_SECS=3600
```

It marks the node `DOWN` only when the pid set has not changed for that long
**and** Slurm agrees no job on the node is still inside its time limit. A job
with no time limit is never enough on its own — those stay held, for you.

Check what it would do without it doing anything:

```bash
clush -w <node> '/cluster/bringup/actions/launch_job.sh --explain'
pdsh -R ssh -w <node> '/cluster/bringup/actions/launch_job.sh --explain'
```

`--explain` traces `WOULD MARK DOWN` and changes nothing.

## When it is the whole fleet

Twenty nodes wedged in tight time clusters is one fault, not twenty. Stop
feeding the sweep into it before you work through them:

```bash
./admin_kill-jobs.sh -p                      # pause fleet-wide, cancel our queued work
sinfo -R | grep -i 'kill task failed'  # the full list, with timestamps
```

`-p` writes `RUN_JOBS=no` for the whole fleet and you lift it by hand — see
[pause-and-resume.md](pause-and-resume.md). Group the nodes by what they were
running and by leaf switch before rebooting any of them; see
[diagnose-a-failed-node.md](diagnose-a-failed-node.md).

The durable fix is outside this tree: `UnkillableStepProgram` in `slurm.conf`
makes Slurm act on the timeout itself rather than drain and strand the node.

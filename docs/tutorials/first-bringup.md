# Your first bringup

By the end of this you will have the framework running on one cluster, one node
tested by one benchmark, and you will have read its result and understood what
the verdict means.

This is the learning path, so it takes the shortest route and makes choices for
you. It deliberately leaves out the options — turning drains on, burn-in,
choosing a benchmark list for a delivery methodology — and points at the how-to
guide for each at the end. Follow it in order; each step is checkable before you
go on.

**You will need:** a Slurm cluster, root on the nodes for one `sudoers` file,
the `cmods` user on the head node and every compute node with passwordless ssh
between them, and one compute node you are willing to test. Budget about an
hour, most of it waiting for an image to download.

## 1. Get the tree onto the cluster

The framework runs from `/cluster/bringup/` on the head node, exported over
NFS to every compute node. A git checkout is a *source* of that tree, never the
tree itself — copy it into place:

```bash
sudo -u cmods cp -a auto-action-trigger/. /cluster/bringup/
cd /cluster/bringup
```

Check it landed with its permissions intact — the exec bits are load-bearing,
and they are easy to lose in transit:

```bash
ls -l agent/node-agent.sh actions/launch_job.sh
```

You want `-rwxr-xr-x` on both. If either is `-rw-r--r--`, `chmod 755` the
scripts in `agent/` and `actions/`; a systemd unit pointed at a non-executable
file starts happily and runs nothing.

## 2. Make your own SETTINGS

```bash
cp SETTINGS.default SETTINGS
```

`SETTINGS.default` ships with the framework and is replaced by every upgrade.
`SETTINGS` is yours and is never overwritten. You have not changed anything yet
— an empty-ish `SETTINGS` inherits every shipped default — but making it now
means the first thing you edit lands in the right file.

## 3. Get one container image

The NCCL benchmarks run out of a container. Download the one public image, which
needs no credentials:

```bash
./build_containers.sh -a arm hpc-benchmarks
./build_containers.sh -a arm -l
```

The second command should show `hpc-benchmarks` present. This takes a few
minutes and is most of the waiting in this tutorial.

You name the images you want; there is no list in `SETTINGS` to leave out. One
is enough here, and the other two the default sweep uses live in a private NGC
org and would fail without a login. Setting that up is
[how-to/build-containers.md](../how-to/build-containers.md), and you do not need
it yet.

## 4. Narrow the sweep to one benchmark, on one node

Open `SETTINGS` and set two lines:

```bash
BENCHMARKS="allreduce"
NODE_FILTER="<your-node>"
```

`NODE_FILTER` is a shell glob, so a bare node name matches exactly that node.
Every other node will trace that it is outside the filter and submit nothing —
which is what you want on a first run.

One benchmark rather than eight, because you are learning to read the output,
not testing the fleet.

## 5. Take a health baseline

Pick a node you have validated by hand — right BIOS, right driver, HCAs up. Its
configuration becomes the definition of "correct" for every other node, so this
choice matters more than it looks:

```bash
bash report_health.sh --refresh <your-node>
```

Wait for one agent cycle (about a minute), then:

```bash
ls logs/<your-node>/
bash admin_set-baseline.sh <your-node>
```

You should see around 45 files, one per check, and `valid-config/default` should
now be a symlink. If `logs/<your-node>/` is empty, nothing is armed yet — that is
the next step, so carry on and come back.

## 6. Confirm sudo, and arm the head node

Seven of the health checks read `dmesg`, one reads `dmidecode`, three walk PCIe
config space, and the drains use `scontrol update`. None of that works from an
unprivileged cycle without a sudo rule — and those rules are the site's to
deploy, via the BCM software image so they survive a reprovision. Nothing here
configures a node. `agent/sudoers.default` is the reference to hand to whoever
owns that image.

Check it is in place before arming anything:

```bash
clush -w <your-node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
pdsh -R ssh -w <your-node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
```

A missing rule does not make a check fail; it makes it produce *different*
output, which reads as bad hardware. `node_health.sh` refuses to run at all
rather than allow that, so a `sudo-REFUSED` here is worth fixing before you go
on. See
[explanation/running-unprivileged.md](../explanation/running-unprivileged.md).

Then, as `cmods` on the head node:

```bash
bash agent/install-agent.sh
```

It works out that this host is the head node, enables lingering, installs
`bringup-supervisor.timer` and starts it. It reports `ok:` or `FAILED:` per step
and exits non-zero if any failed — read that output rather than the exit status
alone. Safe to re-run.

Nothing has to be installed on the compute nodes: the watchdog arms every idle
or drained node itself, within `HEARTBEAT_STALE_MINUTES`. Watch it happen:

```bash
tail -f results/supervisor.log
```

## 7. Watch the first job go out

Do not wait for the hourly cadence. Ask the node what it would do:

```bash
clush -w <your-node> '/cluster/bringup/agent/node-agent.sh --explain'
pdsh -R ssh -w <your-node> '/cluster/bringup/agent/node-agent.sh --explain'
```

`--explain` prints every gate it evaluates and the `sbatch` command it would
issue, and submits nothing. Read that output — it is the clearest picture of the
sequencer you will get. You should see it pass the pause switches, match
`NODE_FILTER`, survey the benchmark list, and end in a `WOULD SUBMIT` line.

If it ends in an `EXIT:` line instead, that line is the reason, and it names
itself. Fix what it says and re-run; nothing here has side effects.

When the `WOULD SUBMIT` looks right, do it for real:

```bash
clush -w <your-node> '/cluster/bringup/actions/launch_job.sh --force -v'
pdsh -R ssh -w <your-node> '/cluster/bringup/actions/launch_job.sh --force -v'
squeue -n bringup-<your-node>
```

`-v` mirrors the trace back through the fan-out; without it the output only reaches
the node's own log.

## 8. Read the result

`allreduce` takes a few minutes. When `squeue` is empty again:

```bash
bash report_job-status.sh <your-node>
```

You will get one of six words. `DONE` means the gate accepted it. `FAIL` means
either the job could not run or it ran and the gate rejected the output — and
the difference is in the file:

```bash
cat results/<your-node>/allreduce.txt
```

The last two lines are the fork. `exit status: 0` under a `FAIL` means the
workload ran clean and the *gate* rejected it, so the reason is in
`report_job-status.sh` rather than in this file. A non-zero exit status is the job's
own verdict, and the cause is somewhere above it.

Now read the number:

```bash
bash report_benchmarks.sh <your-node>
```

The `allreduce` cell holds out-of-place busbw at the largest message size, in
GB/s. That is the same figure `VERDICT_MIN_PEAK_BW_ALLREDUCE` is stated against,
so you can compare the two directly.

**The thing worth understanding here:** that verdict was not stored anywhere. It
was derived from the log file just now, and it will be derived again next time
anything reads it. Change the floor in `SETTINGS` and re-run
`report_job-status.sh` — the same file gets a different verdict, with no re-run of
the benchmark. Try it:

```bash
sed -i 's/^VERDICT_MIN_PEAK_BW_ALLREDUCE=.*/VERDICT_MIN_PEAK_BW_ALLREDUCE=9999/' SETTINGS
bash report_job-status.sh <your-node>       # now FAIL
```

Put it back before you go on:

```bash
sed -i 's/^VERDICT_MIN_PEAK_BW_ALLREDUCE=.*/VERDICT_MIN_PEAK_BW_ALLREDUCE=683/' SETTINGS
```

That property is the reason for most of the design decisions in this tree, and
[explanation/verdicts-and-the-cache.md](../explanation/verdicts-and-the-cache.md)
is where the story is.

## 9. Read the trace

One more file, because it is the one you will use most:

```bash
tail -20 results/<your-node>/trigger.log
```

Every gate the sequencer evaluates writes a line here before it stops. The
newest `EXIT:` line is the reason nothing is happening right now — most likely
`newest result is <n>s old, next sweep in <n>s`, which is the hourly gate doing
its job.

That is the whole diagnostic model: most cycles legitimately have nothing to do,
so the framework writes down *why* it did nothing, and a node that has silently
stopped testing is distinguishable from one that is quietly idle.

## You now have a working bringup

One node, one benchmark, results you can read. Nothing drains yet — both drain
switches ship off, so a failure is reported and never takes a node out of
service.

Where to go from here, in the order most sites need it:

| Next | Guide |
|------|-------|
| Widen to the whole fleet and a real benchmark list | [how-to/enable-a-benchmark.md](../how-to/enable-a-benchmark.md) |
| Get the private-org images | [how-to/build-containers.md](../how-to/build-containers.md) |
| Let failures drain nodes | [how-to/manage-drains.md](../how-to/manage-drains.md) |
| Nothing is running and you do not know why | [how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md) |
| A node failed and you need to know what broke | [how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md) |
| Every setting there is | [reference/settings.md](../reference/settings.md) |
| Why any of it works this way | [explanation/](../explanation/) |

Clear `NODE_FILTER` when you are ready for the fleet to start testing.

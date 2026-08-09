# Arm a node, and check that it stayed armed

Arming a node means enabling lingering for `$JOB_USER` and starting the
`bringup-agent.timer` under that account's `systemd --user`. Normally nobody
does it by hand: the head-node watchdog arms any idle or drained node whose
heartbeat has gone stale. This page is for the first install, for a node the
watchdog has given up on, and for working out which of the two is happening.

Why it is shaped this way is
[explanation/the-agent-and-the-watchdog.md](../explanation/the-agent-and-the-watchdog.md).

## Before anything: the site's three prerequisites

None of these are in the framework's gift, and each fails quietly:

1. **Passwordless ssh from the head node as `$JOB_USER`.** Not as root — the
   watchdog runs as the automation account.
2. **Working `sudo -n` for `$JOB_USER` on every node.** Nothing here configures
   a node; the rules are deployed by the site, via the BCM software image so
   they survive a reprovision. `agent/sudoers.default` is the reference to hand
   to whoever owns that image. Confirm before arming:

   ```bash
   clush -w <node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
   pdsh -R ssh -w <node> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
   ```

   See
   [explanation/running-unprivileged.md#the-sudoers-drop-in](../explanation/running-unprivileged.md#the-sudoers-drop-in).
3. **`results/` and `logs/` writable by `$JOB_USER`.** A tree that has been run
   by root cycles has root-owned directories in it, and nothing repairs them now:

   ```bash
   sudo chown -R cmods:cmods /home/cmods/bringup/results /home/cmods/bringup/logs
   ```

## The first install

On the head node, as `$JOB_USER`:

```bash
bash /home/cmods/bringup/agent/install-agent.sh
```

It works out that this host is the head node — `slurmctld` installed and
`slurmd` not — and installs the watchdog rather than the node agent. Confirm it:

```bash
systemctl --user status bringup-supervisor.timer
tail -f /home/cmods/bringup/results/supervisor.log
```

One line every `SUPERVISOR_INTERVAL_MINUTES`, whether or not it armed anything.
Within `HEARTBEAT_STALE_MINUTES` it should start naming nodes and arming them
over one `clush`. Nothing else is needed: the nodes are armed by the watchdog,
not by you.

If that file is not growing, the journal holds whatever it could not write —
most often a `results/` the account does not own:

```bash
journalctl --user -u bringup-supervisor.service -n 20    # as cmods, on the head node
```

To arm a rack yourself rather than wait:

```bash
clush -w 'ink50-dh01-h02-[11-18]' '/home/cmods/bringup/agent/install-agent.sh'
pdsh -R ssh -w 'ink50-dh01-h02-[11-18]' '/home/cmods/bringup/agent/install-agent.sh'
```

Re-running is safe and is how a changed unit or interval is picked up.

## Is this node armed?

Cheapest first. The heartbeat answers it from the head node, with no ssh:

```bash
stat -c '%n %y' /home/cmods/bringup/results/*/.heartbeat | sort -k2
bash trigger-log.sh          # section 0, fleet-wide
```

A heartbeat written in the last couple of minutes means the timer is firing.
Past `HEARTBEAT_STALE_MINUTES` it is not, and the watchdog is already trying:

```bash
cat /home/cmods/bringup/results/<node>/arm.log    # what it heard back, per attempt
```

To ask the node itself:

```bash
clush -w <node> 'loginctl show-user cmods -p Linger --value; \
    XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active bringup-agent.timer'

pdsh -R ssh -w <node> 'loginctl show-user cmods -p Linger --value; \
    XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active bringup-agent.timer'
```

`yes` and `active` is a healthy node. `trigger-debug.sh --ask-nodes` runs the
same question across everything it found stale, plus the sudo check.

## When a node will not stay armed

The watchdog gives up after `ARM_MAX_ATTEMPTS` in `ARM_WINDOW_HOURS` and names
the node in its summary line rather than sshing at it for ever. What
`arm.log` says usually identifies which of these it is:

| What `arm.log` holds | What it means |
|---|---|
| `no output from clush` | ssh as `$JOB_USER` is not working from the head node to that node |
| `FAILED: could not enable lingering` | polkit refuses, and there is no sudo rule for `loginctl`. `sudo loginctl enable-linger cmods` on the node |
| `FAILED: … does not exist` | the node cannot see `$BRINGUP_HOME` — NFS not mounted, or mounted somewhere else |
| `FAILED: systemctl --user enable --now …` | no user session bus. Almost always lingering that did not take; check it directly |
| armed, but `agent.log` says `scontrol is not on PATH` | the unit is not reaching whatever puts the Slurm tools on `PATH`. Both units run `/bin/bash -lc` for this; a unit installed before that ran the script directly, so re-run `install-agent.sh`. See [run-slurm-commands-remotely.md](run-slurm-commands-remotely.md) |
| `WARNING: sudo as cmods would refuse: …` | armed, and the health checks will not run. The sudoers drop-in is missing |
| nothing at all | the node is not idle or drained, so the watchdog never considered it. `sinfo -n <node>` |

The last row is the one that surprises people. Only `idle` and `drained` nodes
are armed; a node in `allocated`, `down*` or `maint` is left alone, and an agent
that died there is not re-armed until the node comes back to one of the two
states. See
[explanation/the-agent-and-the-watchdog.md#which-states-are-armed](../explanation/the-agent-and-the-watchdog.md#which-states-are-armed).

To clear the give-up counter and let the watchdog try again immediately:

```bash
rm /home/cmods/bringup/results/<node>/arm.log
```

## Running one cycle now, without waiting

```bash
clush -w <node> '/home/cmods/bringup/agent/node-agent.sh --explain'   # decides nothing
pdsh -R ssh -w <node> '/home/cmods/bringup/agent/node-agent.sh --explain'   # decides nothing
clush -w <node> '/home/cmods/bringup/agent/node-agent.sh --verbose'   # a real cycle
pdsh -R ssh -w <node> '/home/cmods/bringup/agent/node-agent.sh --verbose'   # a real cycle
```

`--explain` prints every gate the agent and the three steps under it evaluate,
submits nothing, drains nothing and archives nothing, so it is safe while the
timer is live.

## When the role is wrong

`install-agent.sh` decides for itself whether this host is the head node, and
says which it chose and why:

```
ok: ink50-hn1 is the head node (slurmctld is running here) -- installing bringup-supervisor
ok: ink50-dh01-h02-11 is a compute node (slurmctld is not running here) -- installing bringup-agent
```

It asks three questions in order: does `EXCLUDE_NODES` name this host, is
`slurmctld` running here, and — last — is `slurmctld` installed with `slurmd`
absent. The running check comes first because the third one is the reporting
test, `node_self_excluded`, which requires `slurmd` to be *missing*; a BCM
software image usually installs that unit on every host including the head node,
so on its own it reads a head node as a compute node.

Getting it wrong is quiet in one direction and loud in neither: a head node
armed as a compute node runs `node-agent.sh`, which correctly refuses to do
anything on a host that is not a compute node — and leaves nobody arming the
fleet. Override it when the detection is wrong:

```bash
bash /home/cmods/bringup/agent/install-agent.sh --head
bash /home/cmods/bringup/agent/install-agent.sh --node
```

Naming the head node in `EXCLUDE_NODES` is the durable fix, and it is what keeps
that host out of the reports as well. See
[reference/settings.md#hosts-that-are-not-compute-nodes](../reference/settings.md#hosts-that-are-not-compute-nodes).

## Disarming a node

```bash
clush -w <node> '/home/cmods/bringup/agent/uninstall-agent.sh'
pdsh -R ssh -w <node> '/home/cmods/bringup/agent/uninstall-agent.sh'
```

It stops and removes the timer and the unit, and leaves lingering alone — that
is the site's setting for the account, and turning it off would stop anything
else that account runs. Nothing under `results/` is touched, so re-arming
resumes the sweep where it stopped.

**The watchdog will arm it straight back** as soon as its heartbeat goes stale
and it is idle or drained. To take a node out of the framework rather than
restart it, use `EXCLUDE_NODES` or `NODE_FILTER` in `SETTINGS`, or
`PAUSE_ARMING=yes` to stop the watchdog arming anything at all. See
[pause-and-resume.md](pause-and-resume.md).

**Removing the framework entirely starts at the head node**, for the same
reason: disarm the watchdog first, then the trays, or the trays come back. The
order and what removal deliberately leaves behind are in the README under
*Removing the framework*.

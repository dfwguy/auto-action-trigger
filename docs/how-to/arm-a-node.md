# Arm a node, and check that it stayed armed

Arming a node means enabling lingering for `$JOB_USER` and starting the
`bringup-agent.timer` under that account's `systemd --user`. Normally nobody
does it by hand: the head-node watchdog arms any idle or drained node whose
heartbeat has gone stale. This page is for the first install, for a node the
watchdog has given up on, and for working out which of the two is happening.

Why it is shaped this way is
[explanation/the-agent-and-the-watchdog.md](../explanation/the-agent-and-the-watchdog.md).

## Before anything: the site's four prerequisites

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
4. **`fs.leases-enable = 0` on whichever host exports the tree.** Only there;
   a node that mounts it has no delegation to grant. `install-agent.sh` refuses
   to arm the serving host until it is set, because the failure it prevents
   arrives hours later and looks like a dead watchdog:

   ```bash
   cat /proc/sys/fs/leases-enable   ## want 0
   ```

   See
   [explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations](../explanation/the-fleet-snapshot.md#the-server-must-not-hand-out-delegations).

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
clush -w 'ink50-dh01-h02-[11-18]' '/home/cmods/bringup/agent/install-agent.sh --quiet' | clubak -b
pdsh -R ssh -w 'ink50-dh01-h02-[11-18]' '/home/cmods/bringup/agent/install-agent.sh --quiet' | dshbak -c
```

Re-running is safe and is how a changed unit or interval is picked up.

## One line per node

Run by hand on one node, `install-agent.sh` prints every step it took, which is
what you want when that node is the question. Run over a fan-out it prints that
nine times per host, and a two-hundred-node arm is two thousand lines in which
the four that matter are indistinguishable from the rest. Nobody reads that, so
nobody notices the four.

`--quiet` is the fan-out form. Each host prints exactly one of three things:

| Line | Meaning |
|---|---|
| `ARMED` | lingering on, unit current, timer scheduled, heartbeat written |
| `WARNING: …` | armed, but something it needs is missing — the sudo rules, usually. The cycle will run and part of it will not |
| `FAILED: …` | not armed, and the line names which step |

They partition the fleet: a host says `ARMED` or it says why not, never both.
That is what lets `pause-agents.sh` tally them, and it is why a `WARNING` host
is counted apart from an armed one rather than folded in.

The lines carry no hostname, no timestamp and no pid — deliberately, because
`clubak -b` and `dshbak -c` group on an exact string match, and one varying
character per host defeats the grouping entirely. The fan-out already labels
every line with the node it came from; repeating it inside the message costs the
grouping and buys nothing. Anything genuinely per-host, like the next elapse
time, is in the full output and not in this one.

`pause-agents.sh --resume` and the watchdog both use `--quiet`, so
`results/<node>/arm.log` holds a verdict per attempt rather than a screen of
steps.

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
| `no output from clush` | nothing came back within `FANOUT_COMMAND_TIMEOUT`. Either ssh as `$JOB_USER` does not work from the head node, or the node answered and then blocked — a stale `$BRINGUP_HOME` mount is the usual reason, since `install-agent.sh` sources `settings.sh` off it as its first act. See [../explanation/architecture.md#a-fan-out-is-bounded](../explanation/architecture.md#a-fan-out-is-bounded) |
| `FAILED: could not enable lingering` | polkit refuses, and there is no sudo rule for `loginctl`. `sudo loginctl enable-linger cmods` on the node |
| `FAILED: … does not exist` | the node cannot see `$BRINGUP_HOME` — NFS not mounted, or mounted somewhere else |
| `FAILED: systemctl --user enable --now …` | no user session bus. Almost always lingering that did not take; check it directly |
| `FAILED: bringup-agent.timer active, next elapse never` | the manager is still holding a monotonic unit — it has a `TimersMonotonic=` and no calendar one. See [Armed, but never heartbeats](#armed-but-never-heartbeats) |
| `FAILED: cannot write …/.heartbeat` | `results/<node>` is not writable by `cmods`. `sudo chown -R cmods:cmods /home/cmods/bringup/results` |
| `Unit file … is masked` | a zero-length unit, left by two hosts racing on a shared `$HOME` before the temp file was made unique. Re-run `install-agent.sh`, which replaces an empty unit and unmasks it |
| armed, but `agent.log` says `scontrol is not on PATH` | the unit is not reaching whatever puts the Slurm tools on `PATH`. Both units run `/bin/bash -lc` for this; a unit installed before that ran the script directly, so re-run `install-agent.sh`. See [run-slurm-commands-remotely.md](run-slurm-commands-remotely.md) |
| `WARNING: sudo would refuse: …` | armed, and the health checks will not run. The sudoers drop-in is missing |
| `WARNING: cannot create $NODE_CONTAINER_DIR as cmods` | armed, and jobs still run, off `CONTAINER_DIR` over NFS instead of the node-local cache. `/opt` is root-owned on a stock image; `mkdir -p $NODE_CONTAINER_DIR && chown cmods $NODE_CONTAINER_DIR` as root on the node, once |
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

## Armed, but never heartbeats

The install says `ok:` on every line, `systemctl --user is-active` says `active`,
and the node still never writes `results/<node>/.heartbeat`. The watchdog arms it
again, the install succeeds again, and after `ARM_MAX_ATTEMPTS` it gives up and
names the node. Nothing in any of that says why.

Run one cycle in the foreground. It prints every gate it evaluates, submits
nothing and drains nothing:

```bash
clush -w <node> '/home/cmods/bringup/agent/cycle.sh --verbose'
pdsh -R ssh -w <node> '/home/cmods/bringup/agent/cycle.sh --verbose'
```

If that works and writes a heartbeat, **the cycle is fine and the timer is the
problem** — which is the common case, and there is one cause well ahead of the
others.

### The user manager is not really lingering

`systemd --user` timers only fire while that account's manager is running.
Without effective lingering the manager starts when a session opens and stops
when the last one closes — so arming the node over ssh starts a manager, the
timer fires once a minute later, the session ends, and everything stops. From
outside it looks exactly like a node that armed cleanly and then went quiet,
because that is what it is.

The tell is in the journal: one `Finished bringup-agent.service` at the moment
the node was armed, and nothing after it.

```bash
clush -w <node> 'loginctl show-user cmods -p Linger --value;
    ls -l /var/lib/systemd/linger/ 2>/dev/null;
    ps -o pid,lstart,cmd -u cmods | grep "systemd --user"'
```

`yes`, a `cmods` file in `/var/lib/systemd/linger/`, and a manager whose start
time is **boot**, not a minute ago. A manager that starts when you connect is one
that stops when you leave. See
[explanation/the-agent-and-the-watchdog.md#why-lingering](../explanation/the-agent-and-the-watchdog.md#why-lingering).

`loginctl enable-linger cmods` on the node, as root or through the sudo rule, is
the fix; `install-agent.sh` tries both and reports which it managed.

### The other three, in order

```bash
clush -w <node> 'XDG_RUNTIME_DIR=/run/user/$(id -u) \
    systemctl --user list-timers bringup-agent.timer --no-pager;
    journalctl --user -u bringup-agent.service -n 20 --no-pager'
```

| What you see | What it is |
|---|---|
| the timer is `active` but `NEXT` is `-`, and `systemctl --user show bringup-agent.timer -p TimersCalendar` is empty while `-p TimersMonotonic` is not | it will never fire again. A unit still using `OnUnitActiveSec=` — re-run `install-agent.sh`, which installs the calendar timer. See [explanation/the-agent-and-the-watchdog.md#why-the-timer-is-a-calendar](../explanation/the-agent-and-the-watchdog.md#why-the-timer-is-a-calendar) |
| `is active on the calendar unit this run installed; systemd had not computed a next elapse yet` | not a fault, and the common one on a fleet-wide `--resume`. The manager has the calendar unit loaded and has not worked out its first tick yet. See [explanation/the-agent-and-the-watchdog.md#why-the-next-elapse-is-not-the-question](../explanation/the-agent-and-the-watchdog.md#why-the-next-elapse-is-not-the-question) |
| `systemd reported no next elapse (realtime=[] monotonic=[0])` | not a fault. `systemctl show` did not answer, which is not the same as answering badly — `systemctl --user list-timers` is the readable version. The install says this rather than failing, because failing on an unreadable answer once walled a whole fleet's output with `FAILED` lines for timers that were firing perfectly well |
| the timer absent from `list-timers` | the unit is not loaded — `systemctl --user daemon-reload`, then re-run `install-agent.sh` |
| `Finished bringup-agent.service` once, then nothing | lingering, above |
| `cannot write …/.heartbeat` | `results/<node>` is not writable by `cmods`. `sudo chown -R cmods:cmods /home/cmods/bringup/results` |
| the service failing on every trigger | read the failure — it is a real one, and the cycle prints the same thing under `--verbose` |

To let the watchdog try again once the cause is fixed, rather than waiting out
`ARM_WINDOW_HOURS`:

```bash
rm /home/cmods/bringup/results/<node>/arm.log
```

## When the role is wrong

`install-agent.sh` decides for itself whether this host is the head node, and
says which it chose and why:

```
ok: ink50-hn1 is the head node (slurmctld is running here) -- installing bringup-supervisor
ok: ink50-dh01-h02-11 is a compute node (slurmctld is not running here) -- installing bringup-agent
```

It asks four questions, in this order, and stops at the first that answers:

Both roles install the same unit — `agent/cycle.sh` asks the question again on
every run, so `--head` and `--node` change what the install *checks and prints*,
not what it writes. Why the unit cannot differ by role is
[the-agent-and-the-watchdog.md#one-unit-for-both-roles](../explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles).

| Question | If yes |
|---|---|
| Does `EXCLUDE_NODES` name this host? | head |
| Is `slurmctld` *running* here? | head |
| Is `slurmctld` installed and `slurmd` not? (`node_self_excluded`) | head |
| Is there no `slurmd` unit here at all? | head — Slurm could never schedule to it |
| — | a compute node |

The order matters. `node_self_excluded` is the *reporting* test and needs a
`slurmctld` unit to be present, which a management host that is not the
controller may not have; a BCM software image also tends to install `slurmd`
everywhere, which breaks its other half. So the running check comes first, and
the absence of `slurmd` is the backstop — whatever else a host is, it is not a
compute node if nothing can be scheduled to it.

A head node identified by either of the last two is one the *reports* cannot
recognise on their own, so the install says so and asks for
`EXCLUDE_NODES="<host>"` in `SETTINGS`. Without it the host gets a row of
`NOT_RUN` in every report.

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
`RUN_ARMING=no` to stop the watchdog arming anything at all. See
[pause-and-resume.md](pause-and-resume.md).

**Removing the framework entirely starts at the head node**, for the same
reason: disarm the watchdog first, then the trays, or the trays come back. The
order and what removal deliberately leaves behind are in the README under
*Removing the framework*.

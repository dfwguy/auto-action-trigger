# How the pieces fit together

A `systemd --user` timer on every node runs one agent every two minutes, as
`$JOB_USER` and never as root. A second timer on the head node watches the
heartbeat each node writes to the shared tree and arms any node that has stopped
writing one. Every gate in every script can end a cycle with a plain `exit 0` —
most cycles have nothing to do.

```
head node                          every node under test
─────────────────────────          ────────────────────────────────────────────
bringup-supervisor.timer           bringup-agent.timer  → agent/node-agent.sh
  → agent/supervisor.sh                 │
      sinfo: idle or drained            ├── touch results/<node>/.heartbeat
      stat:  heartbeat stale?           ├── any job on this node? → say so, stop
      clush: install-agent.sh           │
                                        ├── file_copy.sh
                                        │     Rsyncs containers/ to /tmp/containers/ so job
                                        │     start reads the image off local disk.
                                        │
                                        ├── node_health.sh
                                        │     Compares hardware/software state against a
                                        │     known-good baseline, on a cadence rather than
                                        │     once. Sets the node IDLE (all checks pass) or
                                        │     DOWN with a reason (any fail).
                                        │     See explanation/health-cadence.md.
                                        │
                                        └── launch_job.sh
                                              Sequences through benchmarks (dcgmi-r1 →
                                              dcgmi-r3 → allreduce). Submits the next Slurm
                                              job when the node is idle and the prior run
                                              passed. Drains the node if a benchmark fails.
```

Why the pieces are shaped that way — what a heartbeat means, which node states
are armed, why the account lingers — is
[the-agent-and-the-watchdog.md](the-agent-and-the-watchdog.md). What needs root
and what no longer does is
[running-unprivileged.md](running-unprivileged.md). The files are listed in
[reference/layout.md](../reference/layout.md).

## Silence is the enemy

Most cycles legitimately have nothing to do, so "nothing happened" cannot be
distinguished from "the chain is broken" by looking at the cluster. A node that
has silently stopped testing looks exactly like a node that is quietly idle, and
neither shows up in `sinfo`.

The design answer is that every gate writes down why it stopped. Each node keeps
a running trace per step — `results/<node>/agent.log` for the cycle itself,
`results/<node>/trigger.log` for the sequencer and `results/<node>/health.log`
for the health runner — one line per cycle recording
what it did or why it stopped. Every line either can write is in
[reference/trace-lines.md](../reference/trace-lines.md). `trigger-log.sh` reads
those traces across the cluster; `trigger-debug.sh` walks the configuration
behind them when the traces have gone stale. Which to reach for first is
[how-to/diagnose-nothing-running.md](../how-to/diagnose-nothing-running.md).

New gates get a trace line. An `exit 0` with no explanation is a bug even when
the behaviour is correct.

The same principle shapes several decisions that look unrelated:

- A benchmark listed with no `.sbatch` behind it is traced, not skipped in
  silence — see [platform-sets.md](platform-sets.md).
- A saturated controller returns nothing rather than an error, so no answer is
  never treated as an answer — see
  [sequencing.md#when-the-controller-does-not-answer](sequencing.md#when-the-controller-does-not-answer).
- A drain that could not be issued says so, rather than leaving a node that
  looks fine.

## Reaching nodes is clush or pdsh

Nothing in this tree, and nothing in these docs, reaches a node with a bare
`ssh`. Every remote command is a fan-out over a nodeset, and the reason is
scale: a rack is 18 nodes and a cluster is 200-plus, so a command written as an
`ssh` has to be rewritten — as a shell loop, sequentially, with its output
interleaved and unattributed — the first time it is needed on more than one.
Written as a fan-out it never has to be: widening the nodeset from one node to a
whole rack is the whole edit, and output arrives labelled with the node it came
from. The reports print node lists as ranges for exactly this reason — see
[../how-to/get-a-node-list.md](../how-to/get-a-node-list.md).

Two tools do this, and this tree treats them as one:

```bash
clush -w 'ink50-dh01-h02-[11,13-18]' '<command>'
clush -w 'ink50-dh01-h02-[11,13-18]' '<command>'
pdsh -R ssh -w 'ink50-dh01-h02-[11,13-18]' '<command>'
```

They take the same nodeset syntax and both label output `<node>: <line>`, so a
caller parses one format either way and an operator can paste either line. Every
example in these docs is given in both spellings for that reason: a site has one
of the two installed, and nobody should have to translate.

**The automation uses clush.** `fanout.sh` is the one place either is invoked —
`fanout_resolve` picks clush when it is installed, falls back to pdsh with the
fact traced, and refuses with a named reason when neither is there.
`FANOUT_TOOL` in `SETTINGS` pins it to one or the other where a site wants no
ambiguity. clush is preferred because its nodeset handling is a library rather
than a command-line convention — `nodeset`, `--diff` and the group files come
with it — and because `-R ssh` is a wart pdsh forces on every caller.

`-R ssh` is spelled out every time pdsh is used rather than left to the default.
pdsh picks its remote command module at build time, and the packaged builds do
not agree: several default to `rsh`, which is not running here, so the same line
that works on the head node of one cluster fails on another with a connection
refused that names neither `rsh` nor the module. Naming the module makes the
transport a property of the command instead of a property of whichever pdsh
package the site installed. clush has no equivalent problem — ssh is its
default and its `--worker` alternatives are opt-in.

### Nothing is pushed over it

The fan-out carries commands, never files. Arming a node runs
`agent/install-agent.sh` **on** that node, and everything that script installs —
the unit files, the interval, the paths — it reads out of `$BRINGUP_HOME`, which
the node already has mounted over NFS. There is no `scp`, no `rsync` to a node,
and no step where the head node's copy of a file and a node's copy can differ.

That is what makes arming idempotent and cheap enough to do without asking first
whether it is needed, and it is why a tarball drop onto the head node reaches
every node at once. The one thing that *is* copied is the unit file, from the
NFS tree into `~/.config/systemd/user/`, by the node itself — see
[the-agent-and-the-watchdog.md#why-lingering](the-agent-and-the-watchdog.md#why-lingering).

Two exceptions to the fan-out, both deliberate: anything that must run *inside*
Slurm's view of the node uses `srun -w <node>` instead — `ib-visibility.sh` does
— and anything that must run inside the container asks the job's own payload. A
remote shell of any kind lands on the host, which sees a complete and correct
`/dev` no matter what the container saw. See
[containers.md](containers.md) and
[judging-benchmarks.md#host-hcas-are-not-container-hcas](judging-benchmarks.md#host-hcas-are-not-container-hcas).

## One account name

`JOB_USER` is the only place the automation account is written down. It is now
also the account every cycle *runs* as, rather than one that root dropped to at
two points — see [running-unprivileged.md](running-unprivileged.md). The tree
path and the llmb install derive from it — `/home/$JOB_USER/bringup` and
`/home/$JOB_USER/llmb` — so a site moving from a shared human account to an
automation account of its own changes one line in `SETTINGS`.

It did not start that way. The account was a literal in about thirty places:
the `home=` at the top of each action, the NFS container fallback in every
`.sbatch`, and — worst, because it was a *comparison* rather than a path — the
result-ownership check in `trigger-debug.sh`. That one had both failure modes at
once. The top-level test was a prefix glob, so an account whose name began with
the old one passed it; the per-node loop below was an exact match, so the same
tree failed that. One check reported the fleet healthy and correct, the other
reported every node's directory misowned, and neither was right.

The reason a literal survives so long here is that nothing exercises the
difference. Every suite ran as one account, and a name that is wrong everywhere
is still *consistent* — the scripts agree with each other, the tests pass, and
the fleet is broken only on the one cluster that changed it.
`tests/job-user-test.sh` is the answer: it runs the sequencer twice under two
accounts in two trees and requires the traces to be the same text once the name
is substituted out. It also greps the tree, because the differential cannot see
a name that is hardcoded on both sides.

Two things deliberately do *not* derive from `JOB_USER`. The container
directories are their own settings, for the reasons in
[containers.md#one-share-two-mount-points](containers.md#one-share-two-mount-points).
And the agent and the three steps under it find the tree from their own path
rather than from `BRINGUP_HOME`, because they have to load `settings.sh` before
they can read it
— see [../reference/layout.md#runtime-paths](../reference/layout.md#runtime-paths).

## The checkout is not the deployment

The tree runs at `$BRINGUP_HOME` — by default `/home/cmods/bringup/` — on
cluster head nodes, exported over NFS to every compute node. A git checkout is a *source* of that tree, never the tree
itself. Nothing in the repo updates the deployment.

`SETTINGS` is gitignored on purpose: it is the site's file, and a tarball drop
must not overwrite one cluster's node list and drain switches with another's.
`SETTINGS.default` is the shipped copy and *is* tracked.

### Upgrading through a tarball drop

`settings.sh` backfills any key a settings file leaves unset. That is what makes
the tree safe to upgrade through: without it, adding a key would leave every
existing site with a path built from an empty variable, and the failure surfaces
as "no benchmarks found" rather than as anything naming settings.

It is also why editing `SETTINGS.default` in place is the wrong move even though
it works — the next drop replaces that file, and the site's configuration
silently reverts.

## Arming a node

`agent/install-agent.sh` enables lingering for `$JOB_USER`, copies the two unit
files out of `agent/units/` into `~/.config/systemd/user/` with the tree's path
and interval substituted in, and starts the timer. It decides for itself whether
this host is the head node — `slurmctld` installed and `slurmd` not, the same
test as `node_self_excluded` — and installs the watchdog instead where it is.
`agent/uninstall-agent.sh` reverses it, leaving lingering and everything under
`results/` alone.

It is idempotent by design, because the watchdog runs it over `clush` on any node
whose heartbeat has gone stale, without being able to ask first whether it is
needed. It also preflights: a missing exec bit is restored, a missing script or
`systemctl` is a refusal, and a missing sudoers rule is a warning rather than a
refusal — for the reasons in
[running-unprivileged.md#a-lost-rule-must-stop-the-run](running-unprivileged.md#a-lost-rule-must-stop-the-run).

`XDG_RUNTIME_DIR` is set explicitly wherever `systemctl --user` is invoked over
ssh. A non-interactive session does not reliably inherit it, and without it the
failure reads as a missing unit rather than as a missing environment variable.

## BCM is still there, and is not in the path

The head node is a BCM head node, `cmsh` is still how node lists, categories and
device state are read by hand, and nothing here objects to any of that. What
changed is that no part of this framework depends on it: there are no monitoring
actions to register, no triggers to bind, and nothing to unregister when the
framework is paused or removed.

Two things are worth keeping written down, because they cost real time to learn
and are still true of any `cmsh` an operator drives by hand.

`cmsh` exits `0` even when an individual `set` inside a `-c` string was rejected.
It reports the problem on stdout and carries on to the commit, so the exit status
is useless and the output has to be inspected instead. That produced a trigger
with no actions attached that reported success: the object exists, so nothing
looks broken until you notice nothing runs.

Read state with `get <property>`, never by parsing `show`. The column padding and
property names in `show` output drift between BCM releases, so a parser written
against one release quietly matches nothing on the next — the same
silent-empty-result failure this whole framework is written against.

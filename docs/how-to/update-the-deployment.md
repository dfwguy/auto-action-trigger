# Put a new drop on the cluster

The tree runs at `$BRINGUP_HOME` — `/cluster/bringup` at this site — exported to
every node. A checkout or a tarball is a *source* of that tree, never the tree
itself, so updating it is a copy. Two thousand nodes are executing out of that
directory while you copy into it, which is what the steps below are shaped
around.

The whole thing:

```bash
tar xf ~/auto-action-trigger-*.tar.gz -C /tmp      # -C, so this leaves you where you were

bash /cluster/bringup/pause-agents.sh
bash /cluster/bringup/pause-agents.sh --status     # wait for QUIET

rsync -a --delete \
  --exclude=SETTINGS --exclude=results/ --exclude=logs/ --exclude=valid-config/ \
  --exclude=containers/ --exclude=container-src/ --exclude=reports/ --exclude=dmesg-archive/ \
  /tmp/auto-action-trigger-*/ /cluster/bringup/

grep OnCalendar /cluster/bringup/agent/units/bringup-agent.timer   # confirm it landed
bash /cluster/bringup/pause-agents.sh --resume
```

Each step is there for a reason that cost something to learn.

## Unpack on local disk

`$HOME` is NFS-shared at most sites, and it is the busiest directory on the
cluster while the fleet is armed: every node reads `~/.config/systemd/user/` for
its unit and runs a `systemd --user` against it. A drop unpacked there is read
at *that* directory's speed no matter how fast the deployment's own disk is.
`/tmp` is local; use it.

## Stop the fleet before copying, and confirm it stopped

```bash
bash pause-agents.sh
bash pause-agents.sh --status
```

Copying over a tree that two thousand agents are executing out of replaces
scripts under running processes: a cycle that sourced the old `settings.sh` and
then execs the new `node-agent.sh` fails in ways that are genuinely hard to
read. It is also slow, because the copy competes with every node reading the
same files.

`pause-agents.sh` stops the watchdog **first** and locally — it re-arms any node
whose heartbeat goes stale, so stopping the nodes while it runs puts them
straight back — then every node's timer. It writes nothing to the share, which
is what makes it usable when the share is the thing that is struggling.

**Wait for `QUIET`.** `--status` answers two different questions and only one is
about a stop:

```
nodes matching *: 2007 cycling within 10m, 1 stale, 8 never armed
STILL RUNNING: 1975 node(s) wrote a heartbeat in the last 4m (newest 3s ago).
```

The first line is what the *watchdog* arms on; a node stopped a minute ago is
still inside a ten-minute window, so it says nothing about now. The second line
is the answer. `QUIET` means nothing has written a heartbeat for two cycles.

A stop that printed no errors can still have missed a node — one the fan-out
could not reach, one that is not in `sinfo`. One node still cycling is one node
reading the tree while it is replaced.

## `rsync`, not `cp -R`

Three reasons, only the first of which is speed:

- `cp` rewrites all ~700 files whether or not they changed; `rsync` skips the
  ones that match, so the second drop copies a handful.
- `cp` opens each destination `O_WRONLY|O_TRUNC`, so every live script is
  momentarily zero-length. `rsync` writes a temp file and renames, so a reader
  sees the old file or the new one and never a truncated one.
- `--delete` removes files that went away upstream. Without it the deployment
  keeps every script the framework has ever shipped.

**The `--exclude` list is load-bearing because `--delete` is.** Those seven
directories are the site's own data and none of them is in the tarball, so
without the excludes `--delete` removes `SETTINGS`, every result, and the health
baseline. Prove it once:

```bash
rsync -an --delete --exclude=SETTINGS --exclude=results/ --exclude=logs/ \
  --exclude=valid-config/ --exclude=containers/ --exclude=container-src/ \
  --exclude=reports/ --exclude=dmesg-archive/ \
  /tmp/auto-action-trigger-*/ /cluster/bringup/ | grep '^deleting'
```

Only framework files should appear. Anything else means an exclude is missing.

**Read what it says.** A tree carried over from the years these cycles ran as
root has root-owned files in it, and `rsync` cannot overwrite those as
`$JOB_USER`: it reports `Permission denied` per file, exits non-zero, and leaves
the tree **half replaced** — new scripts, old unit files — which is worse than
either. Once, as root:

```bash
sudo chown -R cmods:cmods /cluster/bringup
```

## Confirm what landed, then resume

```bash
grep OnCalendar /cluster/bringup/agent/units/bringup-agent.timer
```

Check the thing that changed rather than trusting an exit status. `install-agent.sh`
can only render what is in the tree, so a half-landed drop means every node is
re-armed with the old unit — and the failure surfaces two thousand lines later,
as timers that never fire.

```bash
bash pause-agents.sh --resume
```

`--resume` re-arms through `agent/install-agent.sh` rather than a bare
`systemctl start`, so it picks up a changed unit or interval, restarts each
node's timer so the running manager is on the current unit, and starts one cycle
immediately rather than leaving the node silent until the first tick. It reports
per node, and the watchdog starts last so it is not arming nodes while that pass
is still going.

Then:

```bash
bash pause-agents.sh --status      # watchdog running, nodes cycling
bash trigger-log.sh                # section 0: heartbeats and the watchdog
```

## What never gets copied

None of this is in the tarball, and all of it has to survive a drop — which is
what the `--exclude` list is protecting:

| Path | What it is |
|---|---|
| `SETTINGS` | The site's configuration. `SETTINGS.default` is the shipped copy and *is* replaced |
| `results/` | Every node's benchmark results, traces and heartbeats |
| `logs/` | Every node's health check output and cadence stamps |
| `valid-config/` | The health baseline. `default` is a relative symlink — `rsync -a` preserves it |
| `containers/`, `container-src/` | The images, and the source staging |
| `reports/`, `dmesg-archive/` | Whatever an operator has kept there |

## Related

- [pause-and-resume.md](pause-and-resume.md) — the `SETTINGS` pause switches,
  and stopping the fleet when the share itself is the problem
- [arm-a-node.md](arm-a-node.md) — what `--resume` runs on each node, and what
  to do when a node will not stay armed
- [explanation/architecture.md#the-checkout-is-not-the-deployment](../explanation/architecture.md#the-checkout-is-not-the-deployment)
  — why the tree is copied rather than checked out

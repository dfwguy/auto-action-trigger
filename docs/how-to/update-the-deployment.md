# Put a new drop on the cluster

The tree runs at `$BRINGUP_HOME` — `/cluster/bringup` at this site — exported to
every node. A checkout or a tarball is a *source* of that tree, never the tree
itself, so updating it is a copy. Two thousand nodes are executing out of that
directory while you copy into it, which is what the steps below are shaped
around.

The whole thing, from a tarball already in `/tmp`:

```bash
# 1. unpack fresh -- the trailing / matches the extracted tree, not the tarball
rm -rf /tmp/auto-action-trigger-*/
tar -jxvf /tmp/auto-action-trigger-*.tar.bz2 -C /tmp

# 2. stop the fleet
bash /cluster/bringup/admin_pause-agents.sh

# 3. copy -- no --delete, so no --exclude list to get wrong
rsync -av /tmp/auto-action-trigger-*/ /cluster/bringup/

# 4. confirm the unit landed -- do not continue if this prints nothing
grep OnCalendar /cluster/bringup/agent/units/bringup-agent.timer

# 5. resume
bash /cluster/bringup/admin_pause-agents.sh --resume
```

**Delete the extracted tree before untarring.** `tar` overwrites what it
extracts but removes nothing, so a file dropped upstream survives in `/tmp` and
`rsync` faithfully copies it back to the cluster. The trailing `/` on the glob
matters: without it, `rm -rf /tmp/auto-action-trigger-*` takes the tarball too.

If several drops have accumulated in `/tmp`, name the tarball rather than
globbing it — `tar` given two archives takes the first and says nothing.

## Unpack on local disk

`$HOME` is NFS-shared at most sites, and it is the busiest directory on the
cluster while the fleet is armed: every node reads `~/.config/systemd/user/` for
its unit and runs a `systemd --user` against it. A drop unpacked there is read
at *that* directory's speed no matter how fast the deployment's own disk is.
`/tmp` is local; use it.

## Stop the fleet before copying

```bash
bash admin_pause-agents.sh
```

Copying over a tree that two thousand agents are executing out of replaces
scripts under running processes: a cycle that sourced the old `settings.sh` and
then execs the new `node-agent.sh` fails in ways that are genuinely hard to
read. It is also slow, because the copy competes with every node reading the
same files.

`admin_pause-agents.sh` stops the watchdog **first** and locally — it re-arms any node
whose heartbeat goes stale, so stopping the nodes while it runs puts them
straight back — then every node's timer. It writes nothing to the share, which
is what makes it usable when the share is the thing that is struggling.

### When the copy misbehaves, check whether it actually stopped

Not a step in the normal path — `rsync` renames rather than truncating, so a
node that missed the stop costs speed rather than correctness. Reach for these
when a copy is slow, sticks on `settings.sh` or `launch_job.sh`, or lands
half-applied:

```bash
bash admin_pause-agents.sh --status                                        # QUIET or STILL RUNNING
find /cluster/bringup-data/results -name .heartbeat -newermt '-2 minutes' # nodes still cycling
```

`--status` prints two different things and only one is about a stop. "N cycling
within `HEARTBEAT_STALE_MINUTES`" is what the *watchdog* arms on; a node stopped
a minute ago is still inside that window. The `QUIET` / `STILL RUNNING` line is
the answer:

```
QUIET: nothing has written a heartbeat in 4m (newest 340s ago). Safe to replace the tree.
STILL RUNNING: 12 node(s) wrote a heartbeat in the last 4m (newest 3s ago).
```

A stop that printed no errors can still have missed a node — one the fan-out
could not reach, one that is not in `sinfo`. Those nodes are reading
`settings.sh` and `launch_job.sh` on every cycle, which are the files a stuck
copy stalls on.

## Why the copy needs no exclude list

A copy only writes what the source has, and **the site's own data is not in the
drop**: `SETTINGS` is gitignored, and `results/`, `logs/`, `valid-config/`,
`containers/`, `container-src/`, `reports/` and `dmesg-archive/` are the
cluster's, never the tarball's. Nothing can overwrite what it does not have. So
there is nothing to exclude.

This procedure used to carry a seven-entry `--exclude` list, a dry run to prove
the list, and a warning that a missing entry deletes the health baseline. Every
one of those existed for `--delete` and for nothing else: `--delete` is the only
thing that can reach a file the source has never heard of. Drop the flag and the
whole apparatus goes with it — the risk and the guard against it were both
self-inflicted.

What `--delete` bought was that a script dropped upstream also leaves the
cluster. Without it the tree accumulates, which breaks nothing and is worth
checking after a drop that removed something:

```bash
src=$(echo /tmp/auto-action-trigger-*/)
fw=(actions agent docs health-checks jobs parsers tests)
comm -13 <(cd "$src" && find "${fw[@]}" -type f | sort) \
         <(cd /cluster/bringup && find "${fw[@]}" -type f | sort)
```

Anything printed is on the cluster and not in the drop; delete it by hand.
`docs/reference/layout.md` and its `layout-doc` CI job cover the top level.

`-v` lists what it transferred. On a normal drop that is a handful of lines,
which is the point: a long list means more changed than you expected, and an
empty one means the copy did nothing.

**Ownership bites.** A tree carried over from the years these cycles ran as root
has root-owned files in it, and `rsync` cannot overwrite those as `$JOB_USER`:
it reports `Permission denied` per file, exits non-zero, and leaves the tree
**half replaced** — new scripts, old unit files — which is worse than either.
Once, as root:

```bash
sudo chown -R cmods:cmods /cluster/bringup
```

### Not `cp -R`, and the reason is not speed

`rsync` writes a temp file and renames it into place. `cp` opens the
destination `O_WRONLY|O_TRUNC` and writes through it — the same inode a running
`bash` is still reading from.

`bash` reads a script lazily, seeking as it executes, so rewriting that inode
under a live cycle resumes it at a byte offset that now means something else.
It is not a torn read that fails cleanly; it is a script that keeps going and
does the wrong thing. Replacing a four-line script under itself, with two
comment lines added above:

```
line A: started
./victim.sh: line 4: am,: command not found     ## resumed mid-token
line A: started                                 ## and re-ran an earlier line
line B: finished cleanly
```

The same replacement by `rsync` prints `line A` and `line B` and nothing else:
the rename leaves the running process on the old inode, which it finishes
reading before anything reopens the path.

That is the whole argument. `cp` also rewrites all ~700 files rather than the
handful that changed, which costs a second and, worse, buries the `-v` list that
tells you what a drop actually did.

### What the stop is still for

The rename means a node that missed `admin_pause-agents.sh` no longer risks a
corrupted script. It does not make the stop optional, because a cycle is
several `bash` invocations and the copy can land between them: `node-agent.sh`
runs `file_copy.sh`, `node_health.sh` and `launch_job.sh` as separate execs, so
a cycle can run the old agent against a new action. Each file is intact and the
combination is one nobody tested.

The exposure is small and bounded — a cycle lasts a second or two out of every
two minutes, so a copy of a few seconds catches a few dozen of the two thousand
nodes mid-cycle, each for exactly one cycle, and the next one two minutes later
is wholly on the new tree. Nothing is corrupted and nothing needs repair.

So: keep the stop. It costs seconds and removes the question, and
`admin_pause-agents.sh` writes nothing to the share. The honest exception is a drop
that touches one file or only `docs/` — there is no skew to have — and even
then the stop is cheaper than deciding whether you are right.

## Confirm what landed, then resume

```bash
grep OnCalendar /cluster/bringup/agent/units/bringup-agent.timer
```

Check the thing that changed rather than trusting an exit status. `install-agent.sh`
can only render what is in the tree, so a half-landed drop means every node is
re-armed with the old unit — and the failure surfaces two thousand lines later,
as timers that never fire.

```bash
bash admin_pause-agents.sh --resume
```

`--resume` re-arms through `agent/install-agent.sh` rather than a bare
`systemctl start`, so it picks up a changed unit or interval, restarts each
node's timer so the running manager is on the current unit, and starts one cycle
immediately rather than leaving the node silent until the first tick. It reports
per node, and the watchdog starts last so it is not arming nodes while that pass
is still going.

Each node reports one line — `ARMED`, or the `WARNING` and `FAILED` lines
saying why not — and identical lines are grouped under a compressed nodeset, so
a clean fleet is two or three lines rather than one per node. See
[arm-a-node.md#one-line-per-node](arm-a-node.md#one-line-per-node). A tally
follows it:

```
208 asked, 205 armed, 2 failed, 1 warned, 0 unreachable
```

### Stragglers are the watchdog's job

`unreachable` is a node that said nothing at all within
`FANOUT_COMMAND_TIMEOUT`. It is named rather than counted, because a node that
answers the ssh and then blocks — a stale NFS mount is the usual reason — is
invisible in every other line of the output.

**Do not re-run `--resume` for those.** They still have a stale heartbeat, so
the watchdog arms them on its next cycle, `ARM_BATCH` at a time, and records
each attempt in `results/<node>/arm.log`. Giving it a cycle and then reading
`check_trigger-log.sh` is both faster and more informative than a second fan-out that
will hang on the same nodes for the same reason. If a node is still unarmed
after `ARM_MAX_ATTEMPTS`, `arm.log` says what it said, and
[arm-a-node.md#when-a-node-will-not-stay-armed](arm-a-node.md#when-a-node-will-not-stay-armed)
reads it.

The stop path is where this is *not* true. A node that does not confirm a stop
may still be cycling out of the tree you are replacing, and no watchdog fixes
that for you — which is why the stop asks each node to echo `STOPPED` and names
the ones that did not, and why `--status` is the gate rather than the stop's own
output. See
[../explanation/architecture.md#a-fan-out-is-bounded](../explanation/architecture.md#a-fan-out-is-bounded).

Then:

```bash
bash admin_pause-agents.sh --status      # watchdog running, nodes cycling
bash check_trigger-log.sh                # section 0: heartbeats and the watchdog
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

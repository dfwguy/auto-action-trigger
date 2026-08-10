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
bash /cluster/bringup/pause-agents.sh

# 3. copy -- the /. copies dotfiles too, and -p keeps the exec bits
cp -Rp /tmp/auto-action-trigger-*/. /cluster/bringup/

# 4. confirm the unit landed -- do not continue if this prints nothing
grep OnCalendar /cluster/bringup/agent/units/bringup-agent.timer

# 5. resume
bash /cluster/bringup/pause-agents.sh --resume
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
bash pause-agents.sh
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

### When the copy misbehaves, check whether it actually stopped

Not a step in the normal path — `rsync` renames rather than truncating, so a
node that missed the stop costs speed rather than correctness. Reach for these
when a copy is slow, sticks on `settings.sh` or `launch_job.sh`, or lands
half-applied:

```bash
bash pause-agents.sh --status                                        # QUIET or STILL RUNNING
find /cluster/bringup/results -name .heartbeat -newermt '-2 minutes' # nodes still cycling
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
cluster's, never the tarball's. So `cp -R` cannot touch any of them. There is
nothing to exclude.

That is worth saying plainly because this procedure used to carry a
seven-entry `--exclude` list, and every one of those entries existed for
`rsync --delete` and for nothing else. `--delete` is what turns a missing
exclude into a deleted health baseline — the risk and the apparatus that guards
against it were both self-inflicted. Dropping the flag drops both.

`-p` keeps the mode bits, which are load-bearing here: a `644` agent script
installs fine and runs nothing. The trailing `/.` copies dotfiles; `src/*` would
silently skip `.gitlab-ci.yml`.

What `cp` gives up, and what to do about it:

- **It rewrites all ~700 files every time.** On local disk with the fleet
  stopped that is a second or two, and it is why there is no `-v` here: a list
  of 700 lines tells you nothing, where `rsync -v`'s handful was the signal.
- **It truncates in place.** Each destination is opened `O_WRONLY|O_TRUNC`, so a
  live script is momentarily zero-length; `rsync` wrote a temp file and renamed.
  This makes step 2 load-bearing rather than merely polite — with `rsync` a node
  that missed the stop cost speed, with `cp` it costs correctness. Confirm the
  fleet is quiet before copying, and see
  [when the copy misbehaves](#when-the-copy-misbehaves-check-whether-it-actually-stopped).
- **It never deletes.** A script dropped upstream stays on the cluster for ever.
  Nothing breaks, but the tree accumulates. Check after a drop that removed
  something:

  ```bash
  src=$(echo /tmp/auto-action-trigger-*/)
  fw=(actions agent docs health-checks jobs parsers tests)
  comm -13 <(cd "$src" && find "${fw[@]}" -type f | sort) \
           <(cd /cluster/bringup && find "${fw[@]}" -type f | sort)
  ```

  Anything printed is on the cluster and not in the drop. Delete it by hand.
  `docs/reference/layout.md` and its `layout-doc` CI job cover the top level.

**Ownership still bites.** A tree carried over from the years these cycles ran
as root has root-owned files in it, and `cp` cannot overwrite those as
`$JOB_USER` any more than `rsync` could: it reports `Permission denied` per
file, exits non-zero, and leaves the tree **half replaced** — new scripts, old
unit files — which is worse than either. Once, as root:

```bash
sudo chown -R cmods:cmods /cluster/bringup
```

### `rsync` as the alternative

Still the better tool when you want the deletion semantics, an itemised list of
what actually changed, or a copy over a slow link. The cost is that the exclude
list comes back, and it is load-bearing the moment `--delete` is:

```bash
rsync -av --delete \
  --exclude=SETTINGS --exclude=results/ --exclude=logs/ --exclude=valid-config/ \
  --exclude=containers/ --exclude=container-src/ --exclude=reports/ --exclude=dmesg-archive/ \
  /tmp/auto-action-trigger-*/ /cluster/bringup/
```

Prove the excludes before trusting them — `-n` is a dry run:

```bash
rsync -an --delete --exclude=SETTINGS --exclude=results/ --exclude=logs/ \
  --exclude=valid-config/ --exclude=containers/ --exclude=container-src/ \
  --exclude=reports/ --exclude=dmesg-archive/ \
  /tmp/auto-action-trigger-*/ /cluster/bringup/ | grep '^deleting'
```

Only framework files should appear. Anything else means an exclude is missing,
and running it for real would take the cluster's history with it.

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
`trigger-log.sh` is both faster and more informative than a second fan-out that
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

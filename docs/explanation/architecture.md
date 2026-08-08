# How the pieces fit together

Three BCM monitoring triggers fire while a node's device status is `UP`
(`duringactions`), so each one re-evaluates on every monitoring cycle without
manual intervention. Every gate in every script can end a cycle with a plain
`exit 0` — most cycles have nothing to do.

```
Node boots → BCM device status = UP
    ├── NodeHealthTrigger → node_health.sh
    │       Compares hardware/software state against a known-good baseline, on a
    │       cadence rather than once. Sets node IDLE (all checks pass) or DOWN
    │       with a reason (any fail). See explanation/health-cadence.md.
    │
    ├── FileCopyTrigger → file_copy.sh
    │       Rsyncs containers/ to /tmp/containers/ so job start reads the image
    │       off local disk. Silent no-op if there is nothing to copy.
    │
    └── LaunchJobTrigger → launch_job.sh
            Sequences through benchmarks (dcgmi-r1 → dcgmi-r3 → allreduce).
            Submits the next Slurm job when the node is idle and the prior run passed.
            Drains the node if a benchmark fails or runs too long.
```

The files are listed in [reference/layout.md](../reference/layout.md).

## Silence is the enemy

Most cycles legitimately have nothing to do, so "nothing happened" cannot be
distinguished from "the chain is broken" by looking at the cluster. A node that
has silently stopped testing looks exactly like a node that is quietly idle, and
neither shows up in `sinfo`.

The design answer is that every gate writes down why it stopped. Each node keeps
a running trace per action — `results/<node>/trigger.log` for the sequencer and
`results/<node>/health.log` for the health runner — one line per cycle recording
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

## Reaching nodes is pdsh, not ssh

Nothing in this tree, and nothing in these docs, reaches a node with a bare
`ssh`. Every remote command is a `pdsh -R ssh -w <nodes> '<command>'`, and the
reason is scale: a rack is 18 nodes and a cluster is 200-plus, so a command
written as an `ssh` has to be rewritten — as a shell loop, sequentially, with
its output interleaved and unattributed — the first time it is needed on more
than one. Written as a `pdsh` it never has to be: widening `-w` from one node
to a whole rack is the whole edit, output arrives labelled with the node it
came from, and `dshbak` will group it. The reports print node lists as ranges
for exactly this reason — see
[../how-to/get-a-node-list.md](../how-to/get-a-node-list.md).

`-R ssh` is spelled out every time rather than left to the default. `pdsh`
picks its remote command module at build time, and the packaged builds do not
agree: several default to `rsh`, which is not running here, so the same line
that works on the head node of one cluster fails on another with a connection
refused that names neither `rsh` nor the module. Naming the module makes the
transport a property of the command instead of a property of whichever `pdsh`
package the site installed.

Two exceptions, both deliberate: anything that must run *inside* Slurm's view of
the node uses `srun -w <node>` instead — `ib-visibility.sh` does — and anything
that must run inside the container asks the job's own payload. A remote shell of
any kind lands on the host, which sees a complete and correct `/dev` no matter
what the container saw. See
[containers.md](containers.md) and
[judging-benchmarks.md#host-hcas-are-not-container-hcas](judging-benchmarks.md#host-hcas-are-not-container-hcas).

## The checkout is not the deployment

The tree runs at `/home/cmods/bringup/` on cluster head nodes, exported over NFS
to every compute node. A git checkout is a *source* of that tree, never the tree
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

## Registering with BCM

`pre-post/create-action-trigger.sh` registers six objects: three monitoring
actions — `node_health_action`, `file_copy_action`, `launch_job_action` — and
one trigger apiece, `NodeHealthTrigger`, `FileCopyTrigger` and
`LaunchJobTrigger`. `pre-post/delete-action-trigger.sh` removes the same six.

cmsh has no upsert, so creation removes each object before adding it; that makes
the script safe to re-run, and it is why the removals are silent — on a first
run there is nothing to remove. The adds are not silent. A registration that
fails quietly is how you end up believing a node is being health-checked when it
is not.

An action is a path plus execution settings. All three run with `runon node` and
`nodeenvironment yes`, so BCM executes the script on the node itself, out of the
NFS-exported tree, with no working directory to infer anything from — hence the
absolute `BRINGUP_HOME` path described under
[reference/layout.md#runtime-paths](../reference/layout.md#runtime-paths). The
timeout is `2m` on all three because `2m` is BCM's hard maximum; anything larger
is rejected outright. The first sync of a container image is multi-gigabyte over
NFS and cannot finish inside that, which is why `file_copy.sh` detaches its
rsync and returns immediately rather than being killed mid-transfer on every
monitoring cycle.

Each trigger attaches its action with `duringactions`, which re-fires on every
monitoring cycle while the device is `UP`. `enteractions` fires only on the
transition into `UP`, so a node that was already up would never pick up a newly
built container image until it rebooted.

Because BCM runs an action by executing the registered path, the exec bit is
part of the contract: a `644` action registers fine, reports success and
silently runs nothing. The exec bit is also easy to lose in transit — a tarball
unpacked through a Windows-mounted path, an `scp` of a single file, an editor
that rewrites rather than edits. So the script preflights the three action
scripts, restores the bit where it can, and refuses to register anything while
one is missing or still not runnable.

## Driving cmsh

Two things about `cmsh` shape every script that touches it.

It exits `0` even when an individual `set` inside the `-c` string was rejected.
It reports the problem on stdout and carries on to the commit, so the exit
status is useless and the output has to be inspected instead — which is what
`cm_run` in `pre-post/create-action-trigger.sh` does, grepping the combined
output for the phrasings BCM uses to refuse. Getting this wrong once already
produced a trigger with no actions attached that still reported success: the
object exists, so nothing looks broken until you notice nothing runs.

Read trigger state with `get <property>`, never by parsing `show`. The column
padding and property names in `show` output drift between BCM releases, so a
parser written against one release quietly matches nothing on the next — the
same silent-empty-result failure the framework is written against.

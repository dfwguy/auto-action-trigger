# Recover a node drained on a full dmesg

For the node that resumes and re-drains on `Prolog error` until its attempt cap
is spent, where the pre-job log says `dmesg is FAIL`. Nothing in the tree clears
this on its own, and
[explanation/drain-recovery.md](../explanation/drain-recovery.md#what-failed-is-written-down-either-way)
says why: only `rogueprocess` can be re-evaluated from outside, so a `dmesg`
flood resumes, fails the next prolog the same way, and burns an attempt each
time.

## Confirm that is what you have

```bash
./overall_report.sh --full 'ink50-dh01-d06*'
```

The line to look for is `prolog   the pre-job check failed on [dmesg]`. If it
says `nothing in results/<node>/trigger.log names the check that failed`, the
trace has rotated — read `recover.log`, whose seventh field keeps the same fact,
or go to BCM's own log on the node:

```bash
clush -w <node> 'grep FAIL $(ls -t /cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs/job.*.log | head -1)'
pdsh -R ssh -w <node> 'grep FAIL $(ls -t /cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs/job.*.log | head -1)'
```

Note the path is under `/cm/local`, which is node-local. Running it on the head
node finds nothing, every time.

## Is syslog enough?

Usually yes, and that is the point of the check. BCM forwards kernel messages to
the head node, so clearing a node's ring buffer normally destroys a *copy*
rather than the record. `dmesg-archive.sh` confirms that per node before it
clears anything, and reports the answer as `syslog:yes` or `NO SYSLOG`.

**The check is local.** It is a `grep` over the syslog of the host you run the
script from — not a fan-out, and the nodes are not asked anything about it. Only
the `dmesg` read and the `dmesg -C` go out to the fleet. So run this from the
head node the cluster forwards to, and read the `long-term copy: … on <host>`
line the run prints to confirm which host that was. On a cluster with more than
one head node, that line is the whole check.

What it matches is the syslog shape, not the bare name:

```bash
grep -hE -- '(^|[[:space:]])<node>[[:space:]]+kernel' /var/log/messages*
```

`<node> kernel:` is a message *from* that host. A bare substring match would
also hit `slurmctld: node <node> drained`, which proves only that something
mentioned it — the opposite of coverage, since a node that never forwards
anything is exactly the one whose buffer is the only copy.

A node with no coverage is saved and **not** cleared. `--force` overrides that;
point `--syslog` at the right glob first if the site forwards somewhere else, or
uses a template this pattern does not fit.

Unreadable logs answer *no*, deliberately. The failure this guards against is
destroying the only record of a hardware fault, so every uncertainty resolves to
not clearing.

## Do it

Dry run first — it expands the node list and runs the syslog check, so the
verdict is real:

```bash
./dmesg-archive.sh -n --clear --resume 'ink50-dh01-d06-[17-18,28-31,33,35-36]'
./dmesg-archive.sh    --clear --resume 'ink50-dh01-d06-[17-18,28-31,33,35-36]'
```

`--resume` is nearly always wanted here. A node that flapped to
`RECOVER_MAX_ATTEMPTS` is left drained for an operator and nothing in the tree
will pick it up again, so clearing the buffer without resuming fixes the cause
and leaves the node out of service.

Three nodes are skipped rather than cleared, and each says which it was:

| Reported | Meaning |
|---|---|
| `EMPTY` | nothing came back. Unreachable, or `dmesg` is root-only there. Never cleared — the buffer was never read |
| `NO SYSLOG` | saved, but the head node has no copy. Not cleared without `--force` |
| `saved` | non-empty and present in syslog. Cleared and resumed |

## What clearing costs

`dmesg -C` takes **seven** health checks to zero, not just the one that drained
the node:

```
32-dmesg-nv_err  33-dmesg-trace  34-dmesg-hw_err  35-dmesg-xid
36-dmesg-knvlink 37-dmesg-ipmi_ssif  38-dmesg-mlx5_core
```

Each is a `dmesg | grep -c`, so an empty buffer matches the baseline and all
seven pass. On a node drained for call traces that is the intent. On a node
also failing `dmesg-xid`, `dmesg-knvlink` or `dmesg-nv_err` it hides a hardware
fault the fleet was correctly reporting — archive those **without** `--clear`
and raise a ticket instead.

`health-check.sh --diff <node>` before and after is how to see which of the
seven were carrying something.

## Reading it back later

```
dmesg-archive/<node>/<YYYYmmdd-HHMMSS>.txt
```

Each file opens with the drain reason as it read at capture time, the command
that gets the same node out of the head node's syslog, and — if the buffer was
cleared — a line recording that, so a node that reads clean afterwards is not
mistaken for one that never had anything wrong.

The directory sits beside `results/`, not inside it, because
`single-node-purge.sh` removes `results/<node>` outright and a kernel log should
outlive a results reset. Nothing prunes it; it is one ring buffer per run.

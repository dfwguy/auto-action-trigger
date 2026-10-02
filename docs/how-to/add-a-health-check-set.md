# Add a health check, or a set for another platform

## Set the baseline first

`valid-config/default` is a symlink to a copy of `logs/<node>` from a node
validated on **this** cluster:

```bash
bash admin_set-baseline.sh <validated-node>
```

Whatever node you name becomes the definition of correct BIOS, OS, kernel
params, IMEX and NVLink for every other node, so validate it by hand first.

It is deliberately not in git (`valid-config/.gitignore`), and it must not be: a
committed `default` pointing at a node name from another cluster gets copied
over the live one on the next tarball drop, and then every check on every node
diffs against a file that isn't there. The symptom is the whole cluster failing
every check at once — `report_health.sh` leads with a `WARNING: no baseline`
banner when the link does not resolve, because nothing below it is real.

## Add one check

1. Drop a numbered file into `health-checks/$HEALTHCHECKS/` — `NN-<name>.sh`,
   mode `644`, with a `# banner:` line. The format is
   [reference/health-checks.md#the-check-file-format](../reference/health-checks.md#the-check-file-format).
2. `bash report_health.sh --refresh <baseline-node>` and let a agent cycle run
   it there.
3. `bash admin_set-baseline.sh <baseline-node>` again, so the baseline has an
   entry for the new check.

**Without that third step the new check diffs against a missing file and fails
on every node.**

## Add a set for another platform

Copy the directory and delete what does not apply — a check that is not there
does not run, which is why this is a directory rather than a pile of `uname`
tests inside one script. Then point `HEALTHCHECKS` at it.

Sets worth having:

| Set | Contents |
|-----|----------|
| `common` | The platform-agnostic subset — bios, os, kernel-params, cpu, memory, numa, dmesg, iface, enroot. The right starting point for a new platform. |
| `hgx-x86` | `common` plus GPU, NVLink, IB and PCIe, minus every IMEX and MNNVL check. Those are GB200/GB300-only and fail identically on every x86 HGX node, which is a whole-cluster drain for hardware that was never there — the same trap that keeps `nvsm` out of the default benchmark list. |
| `cpu-only` | Login, head and CPU compute nodes: `common` plus iface and bond, no GPU or NVLink. |
| `storage` | `common` plus IB, bond and mount checks, no GPU. |

`HEALTHCHECKS` moves independently of `JOBS` and `PARSERS` — see
[explanation/platform-sets.md](../explanation/platform-sets.md).

## Check it before turning drains on

```bash
bash report_health.sh --summary     # where every node stands
bash report_health.sh --diff <node> # why one node was taken down
./tests/health-runner-test.sh      # the runner loop, offline
```

`report_health.sh` groups nodes by the *set* of checks they failed, so one group
is one incident however many nodes are in it, and one node per group is enough
to diagnose — the rest of the group failed the same checks.

Only turn `DRAIN_AFTER_FAILED_HEALTH_CHECK=yes` on once `--summary` reads clean
across the fleet. See [manage-drains.md](manage-drains.md).

## What a clean run resumes

A clean run resumes the node **only if the drain is one it may clear**. It used
to be an unconditional `State=IDLE`, which released whatever had drained the
node — an operator's drain, a benchmark failure `launch_job.sh` had just
recorded, a reservation. Passing the health checks says none of those things; it
says the checks that drained this node no longer fail.

So the decision goes through `slurm-recovery.sh`, which accepts two classes
here: the reasons this script writes itself (recognised by their being check
names), and drains Slurm set itself — a node that failed a prolog and then
passes every check is worth putting back. Everything else, the framework's own
`auto-retry` benchmark drain included, is left alone. See
[explanation/drain-recovery.md](../explanation/drain-recovery.md).

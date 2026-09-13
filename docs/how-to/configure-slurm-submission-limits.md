# Configure Slurm submission limits

The framework deliberately has no fleet-wide job counter. Slurm can reject a
submission atomically, but only when both halves of its accounting policy are
configured:

1. the user association has a `MaxSubmitJobs` value; and
2. `slurmctld` has `AccountingStorageEnforce=limits` enabled.

Setting only the first half stores a number in `slurmdbd`; it does not make the
controller enforce it. A cluster reporting `AccountingStorageEnforce = none`
will continue accepting jobs past `MaxSubmitJobs`.

These commands change site-wide scheduler policy and require a Slurm
administrator. Pause this framework's submissions before changing them; see
[pause-and-resume.md](pause-and-resume.md).

## Check the controller first

Run this on the controller:

```bash
scontrol show config |
    grep -E '^AccountingStorage(Type|Host|Enforce)'
```

The required shape is:

```text
AccountingStorageEnforce = limits
AccountingStorageHost   = <slurmdbd-host>
AccountingStorageType   = accounting_storage/slurmdbd
```

`AccountingStorageEnforce` may be a comma-separated list. It is sufficient for
that list to contain `limits`; `safe` and `all` also imply `limits`. A value of
`none` is not sufficient, even when `sacctmgr` successfully reads and writes
the database.

Before enabling it, audit the association limits already stored in `slurmdbd`.
The change activates all of them, not just the submission limit being added for
this framework:

```bash
sacctmgr show assoc tree \
    format=Cluster,Account,User,Partition,GrpJobs,GrpSubmit,MaxJobs,MaxSubmit,MaxWall
```

## Enable enforcement

First find the file the running `slurmctld` actually read. On the controller,
the current shell gives a useful candidate, but the daemon's own command line
and environment are authoritative:

```bash
printf 'client SLURM_CONF=%s\n' "${SLURM_CONF:-<unset>}"
ctld_pid=$(systemctl show --property=MainPID --value slurmctld)
sudo cat "/proc/$ctld_pid/cmdline" | tr '\0' ' '; echo
sudo cat "/proc/$ctld_pid/environ" | tr '\0' '\n' |
    grep '^SLURM_CONF='
```

Use the pathname after `-f` in the first command when one is present. Otherwise
use `SLURM_CONF` from the second command. The command-line option takes
precedence over the environment. If neither exists, `slurmctld` uses the
configuration directory compiled into that Slurm installation, normally
`/etc/slurm/slurm.conf` for a packaged installation. There is no controller RPC
that reports that compiled fallback; confirm it from the service definition and
the installed package's documentation rather than guessing:

```bash
systemctl cat slurmctld
```

These commands identify the live file, but the file is not necessarily the
authoritative source. A configuration manager may regenerate it. In particular,
BCM writes generated Slurm files below
`/cm/shared/apps/slurm/var/etc/<instance>/`; use Base View or `cmsh` to make the
durable change, then confirm the generated file changed. A direct edit there
can be overwritten by CMDaemon. The default BCM overlays and the server role
that owns its advanced Slurm options are visible with:

```bash
cmsh -c 'configurationoverlay; list'
cmsh -c 'configurationoverlay; use slurm-server; roles; show slurmserver'
```

If the first command shows a differently named overlay carrying the
`slurmserver` role, use that name in the second command.

Set this in the site's authoritative source:

```ini
AccountingStorageEnforce=limits
```

If the setting already contains other values, add `limits` rather than
replacing them.

Apply the configuration and read it back from the running controller:

```bash
sudo scontrol reconfigure
scontrol show config | grep -i '^AccountingStorageEnforce'
```

`scontrol reconfigure` is enough for this setting. The second command must show
`limits`, `safe` or `all` before an association limit can protect the
controller.

## Set the association limit

An association is the combination of cluster, account, user and, optionally,
partition. First identify the association the framework's jobs actually use:

```bash
squeue -h -u USERNAME -o '%a' | sort | uniq -c
sacctmgr show assoc where user=USERNAME \
    format=Cluster,Account,User,Partition,MaxSubmitJobs
```

Set the limit on that association, naming the cluster and account so the
command does not silently change the same user somewhere else:

```bash
sacctmgr modify user \
    where name=USERNAME cluster=CLUSTER account=ACCOUNT \
    set MaxSubmitJobs=1024
```

Repeat the change for every account the framework uses. Jobs charged to another
account use another association and do not consume this one's limit. When an
association is partition-specific, add `partition=PARTITION` to its `sacctmgr`
commands; use `squeue -p PARTITION` when filtering the live queue.

Confirm both the database value and the controller's cached association:

```bash
sacctmgr show assoc \
    where user=USERNAME cluster=CLUSTER account=ACCOUNT \
    format=Cluster,Account,User,Partition,MaxSubmitJobs
scontrol show assoc_mgr users=USERNAME
```

`MaxSubmitJobs` counts the association's pending and running jobs. Once the
association is at the limit, a new `sbatch` is rejected; it is not accepted as
another pending job. `actions/launch_job.sh` records that refusal as `SUBMIT
FAILED` and offers the same eligible work again on a later cycle.

Lowering a limit does not cancel pending or running work already accepted. If
1,600 such jobs exist when the limit becomes 1,024, pending jobs remain queued,
running jobs keep running, and further submissions are rejected until fewer
than 1,024 remain.

## Verify the count that matters

Plain `squeue | wc -l` includes its header and every visible user's jobs. Count
the configured user and group it by account instead:

```bash
squeue -h -u USERNAME -o '%a' | sort | uniq -c
squeue -h -u USERNAME -o '%i|%a|%P|%T' | wc -l
```

If jobs still pass the limit, the three facts to capture together are:

```bash
scontrol show config | grep -i '^AccountingStorageEnforce'
sacctmgr show assoc where user=USERNAME \
    format=Cluster,Account,User,Partition,MaxSubmitJobs
squeue -h -u USERNAME -o '%i|%a|%P|%T'
```

A different account in the last command means the limit was put on the wrong
association. Check the partition too when the site uses partition-specific
associations. `AccountingStorageEnforce = none` means the value is stored but
not enforced.

## Related

- [Slurm accounting and resource limits](https://slurm.schedmd.com/accounting.html#limits)
- [Slurm resource limits](https://slurm.schedmd.com/resource_limits.html)
- [sequencing.md#submission-limits-belong-to-slurm](../explanation/sequencing.md#submission-limits-belong-to-slurm)

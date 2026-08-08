# Run a Slurm command on a node over pdsh

`pdsh -R ssh -w <node> 'squeue ...'` fails with `squeue: command not found` on a
node where `squeue` works perfectly when you log in and type it. This page is
what to add to the command so it runs.

## The short answer

Two things, both on the remote side:

```bash
pdsh -R ssh -w ink50-dh01-g03-11 \
  'SLURM_CONF=/cm/shared/apps/slurm/etc/slurm/slurm.conf \
   /cm/local/apps/slurm/current/bin/squeue -h -j 132500 \
   -O "JobID:|,UserName:|,Name:|,State:|,NodeList:|"'
```

| What | Value here | Why |
|---|---|---|
| absolute path to the tool | `/cm/local/apps/slurm/current/bin/squeue` | the Slurm bin directory is added to `PATH` by the `slurm` module, which is not loaded |
| `SLURM_CONF` | `/cm/shared/apps/slurm/etc/slurm/slurm.conf` | the same module sets it; without it the tool cannot find the controller |

Both paths are BCM's defaults and are what this cluster uses. Confirm a site's
with `pdsh -R ssh -w <node> 'ls -d /cm/local/apps/slurm/current/bin'`.

## Why

`pdsh -R ssh` runs a **non-interactive, non-login** shell. That shell does not
read `/etc/profile` or anything in `/etc/profile.d/`, which is where BCM puts
`modules.sh` — so `module` is not defined, the `slurm` module is never loaded,
and neither the `PATH` entry nor `SLURM_CONF` it would have set exists. Nothing
about this is specific to `pdsh`; a bare `ssh <node> squeue` fails identically,
and an interactive `ssh <node>` followed by typing `squeue` works, which is what
makes it confusing to hit.

The alternative is to source the profile yourself:

```bash
pdsh -R ssh -w ink50-dh01-g03-11 \
  'source /etc/profile.d/modules.sh; module load slurm; squeue -h -j 132500'
```

That is the form the tree uses in code, because it survives a site whose paths
differ from the ones above — `actions/launch_job.sh` opens with exactly those
two lines, and hands the same pair to `su - "$JOB_USER" -c` around every
`sbatch` and every `scancel` it issues. Prefer it when you are writing something
that has to keep working; prefer the explicit paths when you are typing one
command and want to see it fail loudly if a path is wrong.

## Where this bites

- **`get-out-of-the-way.sh`** refuses to do anything when `squeue`, `scancel` or
  `scontrol` is missing from `PATH`, and traces `no-slurm`. Inside a BCM cycle
  the module is already loaded by the time the library is sourced, so this is a
  symptom you see when running the sweep by hand over `pdsh`, not on the cluster
  itself.
- **Anything reading a report over `pdsh`.** `status-check.sh`,
  `health-check.sh`, `daily-report.sh`, `overall_report.sh` and `kill-jobs.sh`
  all call `module load slurm` themselves and say so when it did not help — that
  message means this page, not a broken controller.
- **`squeue -O` field widths.** Unrelated to the shell, but it bites in the same
  session: `-O 'Name:|'` pads every field to 20 characters and the `|`
  separators arrive with the padding attached. Names longer than 20 are *not*
  truncated, so a comparison against a full job name is safe — but it has to be
  trimmed first, which is what `_yield_trim` in `get-out-of-the-way.sh` is for.

## Related

- [get-a-node-list.md](get-a-node-list.md) — turning a report into the `-w`
  argument
- [run-a-job-by-hand.md](run-a-job-by-hand.md) — sweeping a rack with
  `launch_job.sh` over `pdsh -R ssh -w`
- [explanation/architecture.md#reaching-nodes-is-pdsh-not-ssh](../explanation/architecture.md#reaching-nodes-is-pdsh-not-ssh)
  — why every remote command in the tree is written this way

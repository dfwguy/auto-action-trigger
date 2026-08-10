# Run a Slurm command on a node over clush or pdsh

`clush -w <node> 'squeue ...'` fails with `squeue: command not found` on a node
where `squeue` works perfectly when you log in and type it. This page is what to
add to the command so it runs. It is the same answer for `pdsh`, for a bare
`ssh`, and for the `systemd --user` service the agent runs under: none of them
is a login shell.

## The short answer

Two things, both on the remote side:

```bash
clush -w ink50-dh01-g03-11 \
  'SLURM_CONF=/cm/shared/apps/slurm/etc/slurm/slurm.conf \
   /cm/local/apps/slurm/current/bin/squeue -h -j 132500 \
   -O "JobID:|,UserName:|,Name:|,State:|,NodeList:|"'

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
with `clush -w <node> 'ls -d /cm/local/apps/slurm/current/bin'`.

## Why

`clush` and `pdsh -R ssh` both run a **non-interactive, non-login** shell. That
shell does not read `/etc/profile` or anything in `/etc/profile.d/`, which is
where BCM puts `modules.sh` — so `module` is not defined, the `slurm` module is
never loaded, and neither the `PATH` entry nor `SLURM_CONF` it would have set
exists. Nothing about this is specific to either tool; a bare `ssh <node> squeue`
fails identically, and an interactive `ssh <node>` followed by typing `squeue`
works, which is what makes it confusing to hit. The agent hits the same thing
from the other direction, which is why `node-agent.sh` sources `modules.sh` and
loads the module before its first `scontrol`.

The alternative is to source the profile yourself:

```bash
clush -w ink50-dh01-g03-11 \
  'source /etc/profile.d/modules.sh; module load slurm; squeue -h -j 132500'

pdsh -R ssh -w ink50-dh01-g03-11 \
  'source /etc/profile.d/modules.sh; module load slurm; squeue -h -j 132500'
```

That is the form the tree uses in code, because it survives a site whose paths
differ from the ones above — `actions/launch_job.sh` opens with exactly those
two lines, and hands the same pair to the shell around every `sbatch` it
issues. Prefer it when you are writing something
that has to keep working; prefer the explicit paths when you are typing one
command and want to see it fail loudly if a path is wrong.

## Where this bites

- **The watchdog.** `agent/supervisor.sh` is the one host that needs `sinfo`,
  `squeue` and `scancel`, because it asks for the whole fleet — see
  [explanation/the-fleet-snapshot.md](../explanation/the-fleet-snapshot.md). A
  missing tool there stops the node views being written, which stops every agent
  a snapshot age later, so it traces the `PATH` it searched and exits.
- **The agent's own timer.** `systemd --user` gives a service a minimal `PATH`
  and reads no profile at all, so the first `scontrol` fails on exactly the
  hosts where it works when you log in. That is why both units run
  `/bin/bash -lc "<script>"` rather than the script directly, and why the trace
  says what it tried:

  ```
  EXIT: scontrol is not on PATH (unit runs bash -lc, no /etc/profile.d/modules.sh
        here; PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
        -- ... If it works in your login shell, whatever puts it there is not
        reaching this one.
  ```

  A unit installed before that change runs the script directly; re-run
  `agent/install-agent.sh` to pick the new one up.
- **Anything reading a report over `clush` or `pdsh`.** `status-check.sh`,
  `health-check.sh`, `daily-report.sh`, `overall_report.sh` and `kill-jobs.sh`
  all call `module load slurm` themselves and say so when it did not help — that
  message means this page, not a broken controller.
- **`squeue -O` field widths.** Unrelated to the shell, but it bites in the same
  session if you are typing one by hand: `-O 'Name:|'` pads every field to 20
  characters and the `|` separators arrive with the padding attached, and a long
  `NodeList` is truncated outright. Nothing in the tree uses `-O` for that
  reason — `slurm-snapshot.sh` uses `-o` with `%`-style fields, which neither
  pads nor truncates, and puts the free-text reason last.

## Related

- [get-a-node-list.md](get-a-node-list.md) — turning a report into the `-w`
  argument
- [run-a-job-by-hand.md](run-a-job-by-hand.md) — sweeping a rack with
  `launch_job.sh` over `clush -w`
- [explanation/architecture.md#reaching-nodes-is-clush-or-pdsh](../explanation/architecture.md#reaching-nodes-is-clush-or-pdsh)
  — why every remote command in the tree is written this way

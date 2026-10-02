# Running without root

Every cycle used to be root's. BCM ran the three actions with `runon node`, so
`node_health.sh`, `file_copy.sh` and `launch_job.sh` all executed as root on
every node, and the parts that had to be `$JOB_USER` — the `sbatch`, the
`scancel`, the ownership of everything under `results/` — got there by dropping
down with `su - $JOB_USER -c`.

Now the cycle **is** `$JOB_USER`. The systemd timer runs as that account, so the
submission is a plain `bash -lc`, the files are created by the account that has
to write them, and the drop is gone. What is left is a short list of commands
that genuinely need privilege, and they go through `sudo -n`.

That inverts the risk. Before, everything ran with full privilege and the
careful parts gave it up; a bug anywhere in the tree was a bug running as root
on two hundred nodes. Now nothing has privilege and the few things that need it
ask for exactly what they need, by path, from a file the site controls.

## What actually needs root

Less than it looks. Of the 45 health checks, 32 need nothing.

| Command | Used by | Why |
|---|---|---|
| `dmesg` | the seven `3x-dmesg-*` checks | `kernel.dmesg_restrict=1` is the default on these images |
| `dmidecode` | `06-memory.sh`, `45-nodeinfo.sh` | reads `/dev/mem` |
| `lspci -vvv` | `20-pcie-lnk-stat`, `21-pcie-acs`, `22-pcie-mrrs` | extended config space; `LnkSta`, `ACSCtl` and `MaxReadReq` all live past the first 64 bytes |
| `ipmitool` | `37-dmesg-ipmi_ssif.sh`, `44-bmc-firmware.sh`, `45-nodeinfo.sh` | `/dev/ipmi0` |
| `systemctl restart slurmd` | `slurm-recovery.sh` | see [drain-recovery.md#restarting-slurmd](drain-recovery.md#restarting-slurmd) |
| `scontrol update` | the drains and resumes | see [below](#draining-without-root) |
| `loginctl enable-linger` | `install-agent.sh`, when polkit will not let the user do it themselves | see [the-agent-and-the-watchdog.md#why-lingering](the-agent-and-the-watchdog.md#why-lingering) |

`lspci` without `-vvv`, `nvidia-smi`, `ibstatus`, `systemctl is-active` and
every `/sys` and `/proc` read in the check set are unprivileged and stay that
way. `nvidia-smi` is worth calling out because it looks like it should need
root and does not.

## The sudoers drop-in

`agent/sudoers.default` is the shipped reference for what the site has to grant.
Nothing in this tree installs it, and nothing in this tree configures a node at
all: writing to `sudoers.d` needs root, which is the thing being removed, and a
framework that grants itself privilege is not one anybody can audit.

Deploy it through the BCM software image rather than by hand, so it survives a
reprovision — `docs/how-to/enable-nvsm.md` takes the same route for the same
reason. Confirm it landed with the check the framework itself uses:

```bash
clush -w <nodes> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
pdsh -R ssh -w <nodes> 'sudo -n dmesg >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED'
```

`check_trigger-debug.sh --ask-nodes` asks it fleet-wide, and `node-agent.sh --explain`
on a node preflights every command the check set needs and names the missing
ones.

Two things about it are easy to get wrong:

- **The paths must exist.** A rule naming `/usr/bin/scontrol` on a cluster where
  the Slurm client tools are under `/cm/local/apps/slurm/current/bin` is a rule
  that never matches, and `sudo` says so only when it is asked. `visudo -c -f`
  checks the syntax, not the paths.
- **`sudo` is not on the caller's `PATH` by default.** `secure_path` in
  `/etc/sudoers` replaces the environment's `PATH`, and the Slurm tools are not
  on it. So `priv()` resolves the command through the *caller's* `PATH` with
  `command -v` and hands `sudo` an absolute path. That is why a `module load
  slurm` upstream of a drain is load-bearing.

## A lost rule must stop the run

This is the failure this whole area is designed around, and it is not obvious.

A health check that loses privilege does not fail. `sudo -n dmesg` with no rule
prints an error to stderr — which `node_health.sh` keeps outside the baseline in
`$HEALTH_LOG_DIR/<node>/stderr.log`, so
that a tool's own complaint does not end up in the file being diffed — and
produces empty stdout. The check therefore writes a *different* file from the
one the baseline was captured from, the diff against `valid-config/default/`
finds a difference, and the node is reported as a hardware mismatch. With
`DRAIN_AFTER_FAILED_HEALTH_CHECK=yes` it is marked `DOWN`, with a reason naming
seven `dmesg` checks, on a node whose only fault is a missing line in
`sudoers.d`.

So the rules are preflighted before any check runs, and a missing one is a hard
`EXIT:` — no checks, no log, no stamp, no drain:

```
EXIT: sudo as cmods would refuse: /usr/bin/dmesg /usr/sbin/dmidecode -- the
      checks needing them would report something other than what the baseline
      was captured from, so nothing was run and nothing was judged. Those rules
      come from the site's sudoers deployment; agent/sudoers.default is the
      reference for what is missing.
```

Refusing to run is the safe direction here, and it is the opposite of the
default everywhere else in this tree. A gate that cannot answer normally carries
on and writes down why; this one stops, because the alternative is not "no
answer" but "a confident wrong answer about the hardware".

The list is **discovered from the check files**, not written down twice:
`node_health.sh` greps `sudo -n <cmd>` out of `$HEALTHCHECKS_DIR/[0-9]*.sh` and
preflights whatever it finds. A new check that needs a new command is
preflighted without anybody remembering to update a list, and a check that stops
needing one drops out of the preflight by itself. A command that is not
installed at all is skipped — that is not a privilege problem, and the check
already handles its absence.

`install-agent.sh` runs the same preflight and **warns** rather than refusing.
Two of the three steps in a cycle need no privilege, and a node that copies
containers and runs benchmarks is worth more than a node that does nothing; the
refusal belongs at the point where a wrong answer would be produced, which is
the health run itself.

It also asks only about what that host's role uses. On a compute node that is
the discovered check-set list; on the head node it is `scontrol` alone, and only
when `PRIV_SCONTROL` is not `direct` — the watchdog's one privileged call is the
`MAX_JOB_HOURS` drain, and warning a head node about `dmesg` and `ipmitool` it
will never run is noise that teaches an operator to ignore the line.

## Draining without root

`scontrol update State=DRAIN|RESUME|DOWN` is the one privileged operation that
is not a read of local hardware, and it has two supported answers:

- `PRIV_SCONTROL=sudo`, the default, which puts `scontrol` in the sudoers rule.
- `PRIV_SCONTROL=direct`, for a site that has given `$JOB_USER`
  `AdminLevel=Operator` in the Slurm accounting database. That is the tidier
  arrangement — Slurm's own authorization rather than a shell's — and it is
  preferred where the site is willing to make the change.

There is deliberately no automatic detection. A drain that silently stops
working is a node that silently stays in service after failing, and "try it
direct, fall back to sudo" cannot tell a permission failure from a controller
that did not answer. The setting says which one this site chose, and the failure
is loud either way: `scontrol` reports on stdout with a zero exit, so its output
is read rather than its status, and a refusal appears in the trace as
`RECOVER FAILED … sudo: a password is required`.

Only `update` goes through it. `scontrol show node`, `scontrol listjobs` and
`scontrol show hostlist` are reads, run unprivileged, and would break under a
sudoers rule scoped the way the shipped one is.

## The cancel runs as the cycle

`get-out-of-the-way.sh` used to hand its `scancel` to `su - $JOB_USER -c` when
the cycle was root's, so that Slurm's own ownership check sat underneath the
four checks in
[sequencing.md#the-four-checks-before-a-cancel](sequencing.md#the-four-checks-before-a-cancel).
The cycle is now that account, so the `scancel` runs directly and Slurm's check
is still underneath — arrived at by not having privilege rather than by giving
it up.

That removed a branch the test suite could only ever exercise one half of: which
half ran depended on the uid running the suite, so it was green locally and red
in CI for having proved a different thing. `tests/yield-test.sh` now asserts the
same outcome whoever runs it, including root.

## Shared output stays writable by the job group

`results/` and `logs/` are shared operational state. An operator may run a
health check manually, but the next timer cycle still runs as `$JOB_USER`.
`node_health.sh` therefore uses umask `0002`, producing directories as `0775`
and files as `0664` so another account in the same primary group can update
them. Before a due run it also checks the node directory, stamp and existing
check files; an ownership mismatch produces one named `EXIT:` instead of one
shell error for every check.

Existing state from a restrictive umask needs a one-time repair by the site:

```bash
chgrp -R <job-group> "$RESULTS_DIR" "$HEALTH_LOG_DIR"
chmod -R g+rwX "$RESULTS_DIR" "$HEALTH_LOG_DIR"
```

## What is still not the framework's to do

The migration itself needs root, once, and is the site's:

1. The sudo rules on every node, through the software image — see
   [the sudoers drop-in](#the-sudoers-drop-in).
2. `chown -R $JOB_USER:$JOB_USER` over `$RESULTS_DIR` and
   `$HEALTH_LOG_DIR`. Years of root cycles left files and directories in
   there owned by root; nothing repairs them now, because nothing has the
   privilege to. `check_trigger-debug.sh` section 6-7 names them.
3. Passwordless ssh from the head node to every compute node **as `$JOB_USER`**,
   which is how the watchdog arms anything.

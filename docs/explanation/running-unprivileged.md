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

Less than it looks. Of the 38 health checks, 27 need nothing.

| Command | Used by | Why |
|---|---|---|
| `dmesg` | the seven `3x-dmesg-*` checks | `kernel.dmesg_restrict=1` is the default on these images |
| `dmidecode` | `06-memory.sh` | reads `/dev/mem` |
| `lspci -vvv` | `20-pcie-lnk-stat`, `21-pcie-acs`, `22-pcie-mrrs` | extended config space; `LnkSta`, `ACSCtl` and `MaxReadReq` all live past the first 64 bytes |
| `ipmitool` | `37-dmesg-ipmi_ssif.sh` | `/dev/ipmi0` |
| `systemctl restart slurmd` | `slurm-recovery.sh` | see [drain-recovery.md#restarting-slurmd](drain-recovery.md#restarting-slurmd) |
| `scontrol update` | the drains and resumes | see [below](#draining-without-root) |
| `loginctl enable-linger` | `install-agent.sh`, when polkit will not let the user do it themselves | see [the-agent-and-the-watchdog.md#why-lingering](the-agent-and-the-watchdog.md#why-lingering) |

`lspci` without `-vvv`, `nvidia-smi`, `ibstatus`, `systemctl is-active` and
every `/sys` and `/proc` read in the check set are unprivileged and stay that
way. `nvidia-smi` is worth calling out because it looks like it should need
root and does not.

## The sudoers drop-in

`agent/sudoers.default` is the shipped reference, to be installed by the site as
`/etc/sudoers.d/50-bringup`. Nothing in this tree installs it — writing to
`sudoers.d` needs root, which is the thing being removed, and a framework that
grants itself privilege is not one anybody can audit.

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
prints an error to stderr — which `node_health.sh` deliberately discards, so
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
      was captured from, so nothing was run and nothing was judged. Install
      agent/sudoers.default as /etc/sudoers.d/50-bringup.
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

## What is still not the framework's to do

The migration itself needs root, once, and is the site's:

1. `/etc/sudoers.d/50-bringup` on every node.
2. `chown -R $JOB_USER:$JOB_USER` over `$BRINGUP_HOME/results` and
   `$BRINGUP_HOME/logs`. Years of root cycles left files and directories in
   there owned by root; nothing repairs them now, because nothing has the
   privilege to. `trigger-debug.sh` section 6-7 names them.
3. Passwordless ssh from the head node to every compute node **as `$JOB_USER`**,
   which is how the watchdog arms anything.

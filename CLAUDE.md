# Working in this repo

Conventions that are not visible from any single file, and that changes have
broken before. `docs/architecture.md` describes what the pieces are; this
describes what you have to keep true while editing them.

## The checkout is not the deployment

The tree runs at `/home/cmods/bringup/` on cluster head nodes, exported over
NFS to every compute node. A git checkout is a *source* of that tree, never the
tree itself. Nothing in the repo updates the deployment — the user manages
getting it to the cluster. Push to `main`, and open a merge request for major
changes.

`SETTINGS` is gitignored on purpose: it is the site's file, and a tarball drop
must not overwrite one cluster's node list and drain switches with another's.
`SETTINGS.default` is the shipped copy and *is* tracked.

## Executable bits are load-bearing, and not uniform

The split is deliberate. Before changing a mode, work out which of these a file
is:

| Mode | What | Why |
|------|------|-----|
| `755` | Entry points — anything a human or BCM invokes directly | Must be `exec`able. BCM registers an action against a path and runs it; a `644` action registers fine and silently runs nothing |
| `644` | Sourced libraries: `settings.sh`, `reason-map.sh`, `slurm-recovery.sh`, `parsers/*/verdict.sh`, `jobs/*/nccl-hca.sh` | Never executed, only `source`d. `755` would invite running them directly, which does nothing useful |
| `644` | `health-checks/*/NN-*.sh` | `node_health.sh` runs each as `bash "$check_file"` — deliberately, so one check's `exit 1` cannot truncate the set of 38 |
| `644` | `jobs/*/*.sbatch`, including `example.sbatch` | `sbatch` reads them; it does not exec them. `example.sbatch` is a template that gets `cp`'d, so a stray `755` propagates into every new job |

Check the whole tree with:

```bash
git ls-files -s | awk '{print $1, $4}' | sort
```

## Platform sets are directories, not files

`JOBS`, `HEALTHCHECKS` and `PARSERS` in `SETTINGS` each name a subdirectory —
all three ship as `nvl72`. `settings.sh` derives `JOBS_DIR`, `HEALTHCHECKS_DIR`
and `PARSERS_DIR` from them; nothing else should rebuild those paths by hand.

They are separate variables rather than one `PLATFORM` because they do not have
to move together. See `docs/settings.md`.

The failure mode to design against: a name that resolves to a path that does not
exist produces *nothing*, per node, per cycle, quietly. A benchmark listed in
`BENCHMARKS` with no matching `.sbatch` is skipped in silence. Prefer an
explicit check and a written reason over a loop that finds no matches.

## Silence is the enemy

Most cycles legitimately have nothing to do, so "nothing happened" cannot be
distinguished from "the chain is broken" by looking at the cluster. The design
answer is that every gate writes down why it stopped:

- `launch_job.sh` appends one line per cycle to `results/<node>/trigger.log`.
- `trigger-log.sh` reads those traces — run it **first**. Fresh traces mean the
  chain is intact by definition and a gate is closed, and the gate named itself.
- `trigger-debug.sh` checks the configuration that should be producing work.
  Run it when the traces are stale.

New gates get a trace line. An `exit 0` with no explanation is a bug even when
the behaviour is correct.

`cmsh` is a specific offender here: it exits `0` even when a `set` inside the
`-c` string was rejected, reporting the problem on stdout and committing
anyway. Never trust its exit status — inspect its output, as `cm_run` does.
Read trigger state with `get <property>`, not by parsing `show`, whose column
padding and property names drift between BCM releases.

## Before committing

```bash
./tests/verdict-test.sh        # parser gates against captured fixtures
./tests/health-runner-test.sh  # the health check runner loop
./tests/recover-test.sh        # drain classification in slurm-recovery.sh
bash -n <changed script>       # these scripts run as root on 200+ nodes
shellcheck -S warning <changed script>   # CI gates on this; see below
```

The tree is clean at `severity=warning` and CI keeps it that way. A good deal of
what shellcheck flags here is deliberate, so the existing `# shellcheck disable`
directives each carry a reason — several of them describe a "fix" that would
silently break the cluster, like quoting the `grep -v` argument list in the IB
checks. Read the reason before acting on a warning next to one. When a warning
is wrong, add a scoped directive that says why; when the current code is right
but a rewrite is not provably equivalent, the directive *is* the correct
outcome, not a cop-out. `export` is never the way to silence SC2034 in this
tree — it changes the environment every sourcing script and Slurm job runs in.

Keep the tree listing in `docs/architecture.md` in step with the files — it has
drifted twice by adding a top-level script and not listing it.

Commit subjects are `component: lowercase summary`; bodies explain *why*, in
prose, wrapped at 72.

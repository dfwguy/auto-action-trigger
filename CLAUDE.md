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

## Comments point at the docs; they do not contain them

One or two lines and a reference. The reasoning goes in `docs/`, where it can be
read in order, linked to, and found by someone who is not already staring at
that line.

```bash
## Not a tab: `read` collapses runs of IFS whitespace and eats empty fields.
## See docs/operations.md#how-a-report-is-produced.
```

not eight lines restating it above the function. A comment that has grown into
prose is a sign the explanation has no home yet — give it one in `docs/` and
link to it from the code.

Three things are exempt, and only these:

- `# shellcheck disable` directives, which carry their reason inline. That is
  what they are for, and the reason has to sit with the warning it suppresses.
- The six `--help` header blocks, which *are* the help text — see below.
- `.sbatch` files, `jobs/*/*.sh` host launchers and `health-checks/*/NN-*.sh`,
  which are read on their own by people who will not have the docs open.

This is not licence to delete reasoning. Moving an explanation into `docs/` and
dropping it look identical in a diff and are not the same thing.

The exemptions are permission to be self-contained, not to be verbose. They do
not raise the density ceiling below.

### Match the file you are editing

A patch should not read differently from the file around it. Before adding a
comment, look at what the neighbouring lines got: if the twenty settings above
yours are bare assignments under a section header, yours is too. `SETTINGS.default`
is the sharpest case and has been got wrong — a setting there gets a line only
when the *value* is non-obvious, never to explain why the feature exists.

Three questions, and a no to any of them means the comment is not earned:

1. Does it say something the code does not already say? `## Node-local first,
   NFS as fallback` above a line that reads exactly that is noise.
2. Is it one or two lines? Longer means the explanation wants a `docs/` section
   and a reference to it.
3. Would a human skimming for the code thank you for it?

The failure mode this guards against: a file where every line is annotated is
searchable but not readable. Nobody scrolls past a screen of prose to find four
lines of shell, so the comments get skimmed, then trusted, then stale.

Cheap check on a branch before committing — added comment lines against added
code lines, per file. Anything much above the file's own ratio is a rewrite, not
a judgement call:

```bash
git diff main...HEAD --unified=0 -- '*.sh' '*.sbatch' |
awk '/^\+\+\+ /{f=$2} /^\+[^+]/{l=substr($0,2); sub(/^[ \t]+/,"",l);
     if (l ~ /^#/) c[f]++; else if (l != "") k[f]++}
     END {for (x in c) printf "%-40s %d/%d\n", x, c[x], k[x]}'
```

## Executable bits are load-bearing, and not uniform

The split is deliberate. Before changing a mode, work out which of these a file
is:

| Mode | What | Why |
|------|------|-----|
| `755` | Entry points — anything a human or BCM invokes directly | Must be `exec`able. BCM registers an action against a path and runs it; a `644` action registers fine and silently runs nothing |
| `644` | Sourced libraries: `settings.sh`, `reason-map.sh`, `slurm-recovery.sh`, `verdict-scan.sh`, `parsers/*/verdict.sh`, `jobs/*/nccl-hca.sh` | Never executed, only `source`d. `755` would invite running them directly, which does nothing useful. `verdict-scan.sh` is also *run*, but as `bash verdict-scan.sh` from its own `xargs`, like the health checks below |
| `644` | `health-checks/*/NN-*.sh` | `node_health.sh` runs each as `bash "$check_file"` — deliberately, so one check's `exit 1` cannot truncate the set of 38 |
| `644` | `jobs/*/*.sbatch`, including `example.sbatch` | `sbatch` reads them; it does not exec them. `example.sbatch` is a template that gets `cp`'d, so a stray `755` propagates into every new job |
| `644` | `jobs/*/*.sh` — host launchers like `llm-pretrain.sh`, and the sourced `nccl-hca.sh` | `launch_job.sh` runs a host launcher as `bash "$launch"`, like the health checks. A launcher is told apart from a sourced helper by a `job_launch=host` line, not by its mode or name — see `docs/sequencer.md#host-launched-jobs` |

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

## A verdict is derived, and the cache does not change that

The reports cache verdicts in `results/.result_cache.*`, keyed on the gate as
well as on each result file, so editing a floor re-judges the fleet. Anything
added to a verdict that is not a pure function of the result file and the gate
must not be cached. `./tests/scan-cache-test.sh` holds this, and a stale hit is
silent, so that suite is the only thing between a wrong key and a clean-looking
report of a broken cluster.

Read `docs/operations.md#the-verdict-cache` before touching any of it.

## Before committing

```bash
./tests/verdict-test.sh        # parser gates against captured fixtures
./tests/health-runner-test.sh  # the health check runner loop
./tests/recover-test.sh        # drain classification in slurm-recovery.sh
./tests/help-text-test.sh      # --help blocks, if you touched a header comment
./tests/scan-cache-test.sh     # the report cache, if you touched a gate or verdict-scan.sh
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

## Six scripts print their own header as `--help`

`status-check.sh`, `health-check.sh`, `daily-report.sh`, `sync-check.sh`,
`trigger-log.sh` and `build_llmb.sh` implement `-h` as `sed -n '2,NNp'` over
themselves. The line
range is hardcoded, so in those six files **comment length is runtime
behaviour**: shortening a header truncates `--help`, and adding prose below the
block starts printing shell source at whoever typed it. Both pass a
"comments only" review, because that is what they are.

Each carries a sentinel on the line after its range:

```bash
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---
```

Move the sentinel when you move the text, and run `./tests/help-text-test.sh`.
It is the only place in the tree where editing a comment can change what a
script does.

Commit subjects are `component: lowercase summary`; bodies explain *why*, in
prose, wrapped at 72.

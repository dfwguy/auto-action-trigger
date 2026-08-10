# Working in this repo

Conventions that are not visible from any single file, and that changes have
broken before. `docs/explanation/architecture.md` describes what the pieces are; this
describes what you have to keep true while editing them.

## The checkout is not the deployment

The tree runs at `$BRINGUP_HOME` on cluster head nodes, exported to every
compute node. A git checkout is a *source* of that tree, never the tree itself.
Nothing in the repo updates the deployment — the user manages getting it to the
cluster. Push to `main`, and open a merge request for major changes.

`SETTINGS` is gitignored on purpose: it is the site's file, and a tarball drop
must not overwrite one cluster's node list and drain switches with another's.
`SETTINGS.default` is the shipped copy and *is* tracked. Six directories are the
site's too and are never in a drop — `results/`, `logs/`, `valid-config/`,
`containers/`, `container-src/`, `reports/`. Nothing may add them to the
tarball, and nothing may delete on the way in: the drop is a plain `cp -Rp`,
which cannot touch a directory the source does not have. `rsync --delete` can,
and its `--exclude` list is then the only thing between a drop and the
cluster's history — see `docs/how-to/update-the-deployment.md#why-the-copy-needs-no-exclude-list`.

**A change is not deployed until the fleet is re-armed.** Two thousand agents
execute out of that directory, so a drop is stop, copy, confirm, resume — and a
unit file only reaches a node when `install-agent.sh` runs again. Scripts alone
land immediately; units do not. `docs/how-to/update-the-deployment.md` is the
procedure, and it is worth reading before changing anything under `agent/`.

## Comments point at the docs; they do not contain them

**The default is no comment.** Write the code, then add a comment only if you
can say which of the three questions below it passes. This rule is broken more
often than any other here, and always the same way: a subtle fix lands, the
reasoning behind it feels too valuable to lose, and it goes in above the line
instead of into `docs/`. That instinct is right about the value and wrong about
the destination.

**A comment is at most two lines, and a diff must not add more comment lines
than code lines** — per file, checked with the snippet below. Over either
number, the explanation wants a `docs/` section; write it there and leave one
line pointing at it.

`docs/` is where reasoning can be read in order, linked to, and found by someone
who is not already staring at that line. So: one or two lines and a reference.

```bash
## Not a tab: `read` collapses runs of IFS whitespace and eats empty fields.
## See docs/explanation/verdicts-and-the-cache.md#how-a-report-is-produced.
```

not eight lines restating it above the function. A comment that has grown into
prose is a sign the explanation has no home yet — give it one in `docs/` and
link to it from the code.

Three things are exempt, and only these:

- `# shellcheck disable` directives, which carry their reason inline. That is
  what they are for, and the reason has to sit with the warning it suppresses.
- The `--help` header blocks, which *are* the help text — see below.
- `.sbatch` files, `jobs/*/*.sh` host launchers and `health-checks/*/NN-*.sh`,
  which are read on their own by people who will not have the docs open.

This is not licence to delete reasoning. Moving an explanation into `docs/` and
dropping it look identical in a diff and are not the same thing.

The exemptions are permission to be self-contained, not to be verbose. They do
not raise the density ceiling below.

### `docs/` is the source of truth, and it is Diátaxis

The code is not where this tree explains itself. When a fact about *why*
something works the way it does exists in both a comment and `docs/`, the two
drift and the comment is the copy that goes stale unnoticed — nothing reads a
comment on a schedule. So `docs/` holds the reasoning, and the code holds a
pointer to it. Changing behaviour means changing the `docs/` section that
describes it, in the same commit, not afterwards.

`docs/` is organised by [Diátaxis](https://diataxis.fr/) — by what the reader is
doing, not by which script the text is about. Four directories, and a new page
goes in exactly one of them:

| Directory | Answers | Written as |
|---|---|---|
| `docs/tutorials/` | "I have never done this" | one guided path, no options, no alternatives |
| `docs/how-to/` | "I need to do X" | steps for someone who already knows the system |
| `docs/reference/` | "what is this value / flag / line" | dry, complete, scannable — tables, no argument |
| `docs/explanation/` | "why is it like this" | prose, history, trade-offs, the failures that shaped it |

The split that gets got wrong is reference against explanation. A settings table
is reference; *why that default* is explanation. Keep the "why" out of the table
and link to it — a reference page you cannot scan has stopped being one. The
same applies in reverse: an explanation page that lists every flag is a
reference page nobody will find.

A page that needs to be two of these is two pages. `docs/README.md` is the
compass and every page is reachable from it.

Two consequences worth knowing before you move any of it:

- **Anchors are load-bearing.** The code points at `docs/<dir>/<page>.md#<section>`
  several hundred times, and nothing renders those links, so a retitled heading
  resolves silently to the top of the page. `tests/doc-links-test.sh` is the
  gate; run it after touching a heading.
- **The eight `--help` scripts are the exception.** Their header block *is* the
  command surface, and `docs/reference/scripts.md` points at it rather than
  restating it. Two copies of an option list drift, and only one of them is
  testable.

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
code lines, per file. More comment than code fails; anything above the file's
own ratio is a rewrite, not a judgement call:

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
| `755` | Entry points — anything a human or a systemd unit invokes directly, `agent/*.sh` included | Must be `exec`able. The unit names a path and runs it; a `644` agent script installs fine and silently runs nothing, which is why `install-agent.sh` preflights the bit |
| `644` | Sourced libraries: `settings.sh`, `priv.sh`, `fanout.sh`, `reason-map.sh`, `slurm-recovery.sh`, `get-out-of-the-way.sh`, `verdict-scan.sh`, `report-format.sh`, `health-scan.sh`, `parsers/*/verdict.sh`, `jobs/*/nccl-hca.sh` | Never executed, only `source`d. `755` would invite running them directly, which does nothing useful. `verdict-scan.sh` is also *run*, but as `bash verdict-scan.sh` from its own `xargs`, like the health checks below |
| `644` | `agent/units/*.service`, `agent/units/*.timer`, `agent/sudoers.default` | Read, never run. `install-agent.sh` copies the units with `@BRINGUP_HOME@` and `@INTERVAL@` substituted; the sudoers file is a reference the site installs itself, at `0440` |
| `644` | `llmb_check.py` | `build_llmb.sh` runs it as `python3 llmb_check.py`, like the health checks below |
| `644` | `health-checks/*/NN-*.sh` | `node_health.sh` runs each as `bash "$check_file"` — deliberately, so one check's `exit 1` cannot truncate the set of 38 |
| `644` | `jobs/*/*.sbatch`, including `example.sbatch` | `sbatch` reads them; it does not exec them. `example.sbatch` is a template that gets `cp`'d, so a stray `755` propagates into every new job |
| `644` | `jobs/*/*.sh` — the sourced `nccl-hca.sh`, and any host launcher | `launch_job.sh` runs a host launcher as `bash "$launch"`, like the health checks. A launcher is told apart from a sourced helper by a `job_launch=host` line, not by its mode or name — see `docs/explanation/sequencing.md#host-launched-jobs`. No job ships as one today |

Check the whole tree with:

```bash
git ls-files -s | awk '{print $1, $4}' | sort
```

## Reaching a node is `clush -w` or `pdsh -R ssh -w`, never a bare `ssh`

**The automation uses clush.** `fanout.sh` is the only place either tool is
invoked: `fanout_resolve` prefers `clush`, falls back to `pdsh` with the fact
traced, and refuses with a named reason when neither is installed. `FANOUT_TOOL`
pins it. Nothing calls `clush` or `pdsh` directly, and nothing calls `ssh` at
all — a command written as an `ssh` has to be rewritten the first time it is
wanted on more than one node.

**Every example gives both spellings**, in `docs/` and in the lines scripts
*print* for an operator to paste:

```bash
clush -w '<nodes>' '<cmd>'
pdsh -R ssh -w '<nodes>' '<cmd>'
```

A site has one of the two installed and nobody should have to translate; the two
take the same nodeset syntax and both label output `<node>: <line>`, so a caller
parses one format either way. `fanout_example` prints the pair. `-R ssh` is
always spelled out on the pdsh form: `pdsh` picks its rcmd module at build time
and several packaged builds default to `rsh`, so the default is not portable
between sites.

**The fan-out carries commands, never files.** Arming a node runs
`agent/install-agent.sh` *on* that node, and everything it installs it reads out
of `$BRINGUP_HOME` over NFS. There is no `scp` and no push, which is what makes
arming idempotent and a tarball drop on the head node reach every node at once.

The exceptions are `srun -w <node>` where the command must run inside Slurm's
view, and the job payload itself where it must run inside the container. See
`docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh`.

## Platform sets are directories, not files

`JOBS`, `HEALTHCHECKS` and `PARSERS` in `SETTINGS` each name a subdirectory —
all three ship as `nvl72`. `settings.sh` derives `JOBS_DIR`, `HEALTHCHECKS_DIR`
and `PARSERS_DIR` from them; nothing else should rebuild those paths by hand.

They are separate variables rather than one `PLATFORM` because they do not have
to move together. See `docs/reference/settings.md`.

The failure mode to design against: a name that resolves to a path that does not
exist produces *nothing*, per node, per cycle, quietly. A benchmark listed in
`BENCHMARKS` with no matching `.sbatch` is skipped in silence. Prefer an
explicit check and a written reason over a loop that finds no matches.

## Silence is the enemy

Most cycles legitimately have nothing to do, so "nothing happened" cannot be
distinguished from "the chain is broken" by looking at the cluster. The design
answer is that every gate writes down why it stopped:

- `node-agent.sh` touches `results/<node>/.heartbeat` before every gate — it
  says the timer fired, never that the cycle did work — and appends one line per
  cycle to `results/<node>/agent.log`.
- `launch_job.sh` appends one line per cycle to `results/<node>/trigger.log`.
- `trigger-log.sh` reads those traces — run it **first**. Fresh traces mean the
  chain is intact by definition and a gate is closed, and the gate named itself.
- `trigger-debug.sh` checks the configuration that should be producing work.
  Run it when the traces are stale.

New gates get a trace line. An `exit 0` with no explanation is a bug even when
the behaviour is correct. `file_copy.sh` was the last step without one, and the
cost was months of "the images are not built yet" and "the images never arrived"
being the same silence.

### No answer is not an answer

Every query that can come back empty has a caller that fails towards *not*
acting. A saturated `slurmctld` returns nothing rather than an error; a
`systemctl show` that does not answer is not a broken timer; a `scontrol
listjobs` that fails reads as *busy*, never as idle. Getting this backwards is
how a check written to catch a silent failure produced two thousand `FAILED`
lines for timers that were firing perfectly well.

Three outcomes, not two, wherever a probe can be inconclusive: it worked, it is
definitely broken, or **it did not say** — and the third prints what the tool
actually returned rather than a verdict.

### Verify the outcome, not the request

Every line an installer prints about what it *asked* the system to do is worth
less than one line about what is now true. `install-agent.sh` reported six
cheerful `ok:` lines while leaving a node that never ran a cycle, because every
one of them described a request. It now checks that the timer is scheduled and
that the node can write its own heartbeat — the two facts the fleet depends on —
and those are what caught the next three faults.

Nothing in the tree drives `cmsh` any more — the chain is a `systemd --user`
timer per node and a watchdog on the head node, and BCM is not in it. When you
reach for `cmsh` by hand, two things still hold: it exits `0` even when a `set`
inside the `-c` string was rejected, reporting the problem on stdout and
committing anyway, so never trust its exit status; and read state with
`get <property>`, not by parsing `show`, whose column padding and property names
drift between BCM releases.

## Nothing may depend on how long something else took

A cycle runs three steps; anything that has to outlive the cycle gets its own
transient unit through `systemd-run --user --collect`, never a `setsid ... &`
child. `setsid` escapes the session and not the cgroup, so a background child is
killed when `ExecStart` returns — which gives it whatever is left of a cycle
whose length nothing chose and nothing bounds, anywhere from milliseconds to
seconds depending on what the other two steps decided to do. The container copy
lost that race for a fleet-wide fill and looked like slow progress rather than a
fault.

If a thing needs to run to completion, give it a unit. The same rule applies to
anything added later that takes longer than a cycle.

## Fleet arithmetic: multiply everything by the node count

Every read in a cycle is multiplied by the fleet. One file per cycle is 17 reads
a second across two thousand nodes, sustained, for ever — so work belongs
**below** the gate that decides whether the work happens, even when the code
reads worse for it. The sudo preflight read all 38 check files above the cadence
gate and cost 640 reads a second for an answer worth having every four hours.

The same arithmetic applies to fan-out: `ARM_BATCH` caps how many nodes one
watchdog cycle reaches, because a fleet that stops cycling for any reason makes
*every* node stale in the same instant, and an uncapped pass is one ssh per node
from one host.

## A shared `$HOME` is a shared everything

`~/.config/systemd/user/` is on NFS at most sites, so every node reads the same
unit files and the same `systemctl --user enable` state. Two units differing by
role cannot survive that — enabling one on the head node enables it fleet-wide —
which is why there is **one** unit and `agent/cycle.sh` decides the role at run
time. It is also why a temp file written there carries `$HOSTNAME.$$`: two
thousand hosts writing one directory in one fan-out took each other's file and
left a zero-length unit, which systemd reports as `masked`.

Assume anything under `$HOME` is being written by two thousand hosts at once.

## A verdict is derived, and the cache does not change that

The reports cache verdicts in `results/.result_cache.*`, keyed on the gate as
well as on each result file, so editing a floor re-judges the fleet. Anything
added to a verdict that is not a pure function of the result file and the gate
must not be cached. `./tests/scan-cache-test.sh` holds this, and a stale hit is
silent, so that suite is the only thing between a wrong key and a clean-looking
report of a broken cluster.

Read `docs/explanation/verdicts-and-the-cache.md#the-verdict-cache` before touching any of it.

## Before committing

```bash
./tests/verdict-test.sh        # parser gates against captured fixtures
./tests/health-runner-test.sh  # the health check runner loop
./tests/recover-test.sh        # drain classification in slurm-recovery.sh
./tests/dmesg-archive-test.sh  # what dmesg-archive.sh refuses to clear, if you touched it
./tests/help-text-test.sh      # --help blocks, if you touched a header comment
./tests/scan-cache-test.sh     # the report cache, if you touched a gate or verdict-scan.sh
./tests/yield-test.sh          # the cancel gates, if you touched get-out-of-the-way.sh
./tests/llmb-check-test.sh     # llmb install discovery, if you touched llmb_check.py
./tests/exclude-test.sh        # the head-node gate, if you touched EXCLUDE_NODES or a results/*/ walk
./tests/health-cadence-test.sh # the gates in node_health.sh, if you touched the cadence or the baseline
./tests/report-format-test.sh  # node-list wrapping, if you touched report-format.sh
./tests/health-scan-test.sh    # the health verdict, if you touched health-scan.sh
./tests/health-report-test.sh  # the buckets and --drained, if you touched health-check.sh
./tests/job-user-test.sh      # the two-account differential, if you touched JOB_USER, a path derived from it, or CONTAINER_DIR
./tests/agent-test.sh          # the heartbeat, the busy gate and the lock, if you touched node-agent.sh
./tests/supervisor-test.sh     # which nodes get armed, if you touched supervisor.sh
./tests/priv-test.sh           # the sudo layer, if you touched priv.sh or a check that needs root
./tests/fanout-test.sh         # clush before pdsh, if you touched fanout.sh
./tests/next-run-test.sh       # the buckets, if you touched next-run.sh or either cadence
./tests/doc-links-test.sh      # every docs/ anchor the code points at, if you moved or retitled one
bash -n <changed script>       # these scripts run as root on 200+ nodes
shellcheck -S warning <changed script>   # CI gates on this; see below
```

Run the comment-ratio check from the section above as well, and act on it: a
file over its ratio gets the explanation moved into `docs/` and a reference left
behind, before the commit, not in a follow-up that never comes.

The tree is clean at `severity=warning` and CI keeps it that way. A good deal of
what shellcheck flags here is deliberate, so the existing `# shellcheck disable`
directives each carry a reason — several of them describe a "fix" that would
silently break the cluster, like quoting the `grep -v` argument list in the IB
checks. Read the reason before acting on a warning next to one. When a warning
is wrong, add a scoped directive that says why; when the current code is right
but a rewrite is not provably equivalent, the directive *is* the correct
outcome, not a cop-out. `export` is never the way to silence SC2034 in this
tree — it changes the environment every sourcing script and Slurm job runs in.

Keep the tree listing in `docs/reference/layout.md` in step with the files — the
`layout-doc` CI job fails on a top-level script that is not listed, and it has
drifted twice.

A change under `agent/units/` is not testable from a checkout: the suites stub
systemd, and a unit only takes effect when `install-agent.sh` rewrites and
restarts it on every host. Say so in the commit, because the reader deploying it
needs `pause-agents.sh --resume` and not just a copy.

## Privilege is asked for, never held

No cycle runs as root. The agent is `$JOB_USER` under that account's
`systemd --user`, and the few commands that need more go through `priv()` in
`priv.sh` — `sudo -n <absolute path>`, against a rule the site installs from
`agent/sudoers.default`. A health check that needs root says `sudo -n` inline,
because those files are read and run on their own.

The failure this guards against is not a check that fails; it is a check that
**succeeds differently**. A refused `sudo` prints to stderr, which the runner
discards, and produces empty stdout — so the check writes a file the baseline
does not match, and the node is reported as bad hardware. So `node_health.sh`
preflights every `sudo -n <cmd>` it finds in the check set and refuses to run at
all when one would be denied. Read
`docs/explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run` before
changing any of it.

## Some scripts print their own header as `--help`

`status-check.sh`, `health-check.sh`, `overall_report.sh`, `daily-report.sh`,
`trigger-log.sh`, `kill-jobs.sh`, `check_squeue.sh` and
`build_llmb.sh` implement `-h` as `sed -n '2,NNp'` over themselves — `tests/help-text-test.sh`
discovers them rather than listing them, so the set is whatever greps for the
idiom. The line
range is hardcoded, so in those files **comment length is runtime
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

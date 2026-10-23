# Contributor reference

Detailed conventions and validation commands for contributors, including AI
assistants. Start with the shared instructions in [AGENTS.md](../../AGENTS.md).
The component explanations live in [the documentation index](../README.md).

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

### Documentation structure

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
- **Scripts with self-printing `--help` headers are the exception.** Their header block *is* the
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

## Before committing

```bash
./tests/verdict-test.sh        # parser gates against captured fixtures
./tests/health-runner-test.sh  # the health check runner loop
./tests/recover-test.sh        # drain classification in slurm-recovery.sh
./tests/dmesg-archive-test.sh  # what check_dmesg.sh refuses to clear, if you touched it
./tests/help-text-test.sh      # --help blocks, if you touched a header comment
./tests/scan-cache-test.sh     # the report cache, if you touched a gate or verdict-scan.sh
./tests/launch-job-archive-test.sh # .prevN/.failN archiving, if you touched archive_result or submit_one
./tests/burnin-hours-test.sh   # the round-robin, the BURNIN_HOURS gate and the report cell, if you touched burn-in scheduling or reporting
./tests/continue-running-test.sh # the continuous re-run tier, if you touched CONTINUE_RUNNING_JOBS or its priority against BENCHMARKS/BURNIN
./tests/yield-test.sh          # the cancel gates, if you touched get-out-of-the-way.sh
./tests/llmb-check-test.sh     # llmb install discovery, if you touched llmb_check.py
./tests/exclude-test.sh        # the head-node gate, if you touched EXCLUDE_NODES or a results/*/ walk
./tests/health-cadence-test.sh # the gates in node_health.sh, if you touched the cadence or the baseline
./tests/report-format-test.sh  # node-list formatting and prose wrapping, if you touched report-format.sh
./tests/brief-report-test.sh   # the one-line report, if you touched report_overall.sh
./tests/health-scan-test.sh    # the health verdict, if you touched health-scan.sh
./tests/health-report-test.sh  # the buckets and --drained, if you touched report_health.sh
./tests/job-user-test.sh      # the two-account differential, if you touched JOB_USER, a path derived from it, or CONTAINER_DIR
./tests/agent-test.sh          # the heartbeat, the busy gate and the lock, if you touched node-agent.sh
./tests/supervisor-test.sh     # which nodes get armed, if you touched supervisor.sh
./tests/arm-timer-test.sh      # the timer-is-scheduled and lingering-bus gates, if you touched install-agent.sh
./tests/build-containers-test.sh # -a required and the nvcr.io login gate, if you touched build_containers.sh
./tests/priv-test.sh           # the sudo layer, if you touched priv.sh or a check that needs root
./tests/fanout-test.sh         # clush before pdsh, if you touched fanout.sh
./tests/next-run-test.sh       # the buckets, if you touched check_next-run.sh or either cadence
./tests/abup-test.sh           # the group/name dispatch, if you touched abup or added a <group>_<name>.sh
./tests/doc-links-test.sh      # every docs/ anchor the code points at, if you moved or retitled one
bash -n <changed script>       # syntax check; no cluster access needed
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
needs `admin_pause-agents.sh --resume` and not just a copy.

## Some scripts print their own header as `--help`

`report_job-status.sh`, `report_health.sh`, `report_overall.sh`, `report_benchmarks.sh`,
`check_trigger-log.sh`, `admin_kill-jobs.sh`, `check_squeue.sh`,
`build_llmb.sh`, `check_dmesg.sh`, `check_next-run.sh` and `admin_pause-agents.sh`
implement `-h` as `sed -n '2,NNp'` over themselves — `tests/help-text-test.sh`
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

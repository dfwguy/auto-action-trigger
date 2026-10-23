# Working in this repository

These are the shared repository instructions for every AI assistant. Read this
file before changing the tree, then read the linked documentation for the
components you touch. Tool-specific entry points must only refer to this file;
do not maintain another copy of the rules.

## Project and navigation

This is an automated Slurm cluster bring-up and validation framework. It runs
health checks, caches container images, sequences benchmarks and optional
burn-in, and reports fleet status.

- `agent/`: systemd user timer, runtime role selection, node agent and watchdog.
- `actions/`: health runner, image copy and benchmark submission.
- `jobs/`, `health-checks/`, `parsers/`: platform-specific sets.
- `settings.sh`: site settings resolution, defaults and derived paths.
- `report_*.sh`, `check_*.sh`, `admin_*.sh`: operator entry points.
- `tests/`: offline suites that stub cluster commands.
- [Documentation index](docs/README.md): tutorials, how-to guides, references
  and explanations. [Layout](docs/reference/layout.md) lists files and modes.

## Durable knowledge

A fresh session must be able to work from the repository and the user's task
without private project memory. Record durable rules here, technical knowledge
in `docs/`, and reproducible requirements in tests where practical. Local
memory may hold temporary task state or personal preferences, but must not be
the only source of a project requirement. Never put credentials or site-private
configuration in shared instructions.

When new information changes a project requirement, update its canonical source
in the same change. Keep adapters free of separate policies. The
[contributor workflow](docs/how-to/contribute.md) covers memory migration and
checking instruction discovery in a fresh session.

## Deployment and site data

- A checkout is a source for `$BRINGUP_HOME`, never a live deployment. Do not
  deploy or change cluster state as part of an ordinary code edit.
- Preserve site-owned `SETTINGS`, `SETTINGS_HOME` and runtime data. Shipped
  defaults are tracked separately. Resolve settings through `settings.sh`;
  do not assume `SETTINGS` lives beside the scripts.
- Deployment is stop, copy with `rsync -av` without `--delete`, confirm, resume.
  Do not copy over running scripts with `cp -R`. Unit changes reach nodes only
  after `install-agent.sh` runs again. State that requirement in the change.
- Keep site data out of release drops. Read the
  [deployment procedure](docs/how-to/update-the-deployment.md) before changing
  installation or packaging.
- Work on a branch and prepare a merge request; do not push directly to `main`.

## Runtime constraints

- Cycles run as `$JOB_USER`, not root. Privileged operations go through
  `priv.sh`; standalone health checks use explicit `sudo -n`. Sudo rules are
  site-managed. Read [privilege behavior](docs/explanation/running-unprivileged.md)
  before changing it: refused commands must not become false hardware findings.
- Use `fanout.sh` for remote automation. Operator examples must show both
  `clush -w` and `pdsh -R ssh -w`; do not add bare SSH or file pushes. Slurm
  steps may use `srun`. See [remote access](docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh).
- `JOBS`, `HEALTHCHECKS` and `PARSERS` name directories. Use `JOBS_DIR`,
  `HEALTHCHECKS_DIR` and `PARSERS_DIR` from `settings.sh`. Missing sets or
  launchers must be explained, not mistaken for completed work.
- Every new gate must trace why it stops. Diagnose fresh traces with
  `check_trigger-log.sh`, and stale traces with `check_trigger-debug.sh`.
- Distinguish success, definite failure and an inconclusive probe. Empty or
  failed queries must not grant permission to act. Verify outcomes such as a
  scheduled timer and writable heartbeat, not just successful command exits.
  See [diagnostic design](docs/explanation/architecture.md#silence-is-the-enemy).
- Assume `$HOME` and unit files are shared across the fleet. Keep one unit for
  both roles, decide the role at runtime, and use host/process-specific temp
  filenames. See [shared units](docs/explanation/the-agent-and-the-watchdog.md#one-unit-for-both-roles).
- Work that outlives a cycle needs its own transient unit via
  `systemd-run --user --collect`; `setsid` does not escape the service cgroup.
  See [container copying](docs/explanation/containers.md#the-copy-is-its-own-unit).
- Multiply recurring reads and remote calls by the node count. Put expensive
  work below cadence gates and keep watchdog fan-out bounded. See
  [fleet costs](docs/explanation/the-agent-and-the-watchdog.md#what-a-cycle-costs-the-share).
- Verdicts are derived from result files and parser settings. Cache only pure
  results and include every verdict input in cache invalidation. Read
  [the verdict cache](docs/explanation/verdicts-and-the-cache.md#the-verdict-cache)
  before touching gates or caching.

## Editing conventions

- Match the surrounding code and preserve executable modes; entry points and
  sourced/read files deliberately differ. See the
  [mode table](docs/reference/layout.md#executable-bits).
- Keep reasoning in `docs/` and short pointers in code. Comments are at most
  two lines, and added comments must not outnumber added code per file. The
  exceptions and ratio check are in the
  [contributor reference](docs/reference/contributing.md#comments-point-at-the-docs-they-do-not-contain-them).
- Organize documentation by Diátaxis, link new pages from `docs/README.md`, and
  update behavior documentation in the same commit. Preserve existing anchors.
- Some scripts print their header as `--help`. Header length and its sentinel
  are runtime behavior; see the
  [help convention](docs/reference/contributing.md#some-scripts-print-their-own-header-as---help).
- Keep justified, scoped ShellCheck suppressions. Do not export variables just
  to silence SC2034; exporting changes child and Slurm job environments.

## Validation and handoff

- Run the applicable checks in the
  [test selection reference](docs/reference/contributing.md#before-committing).
  For shell edits, run `bash -n` and `shellcheck -S warning` on changed scripts.
- Run `./tests/doc-links-test.sh` for documentation or anchor edits. Keep
  `docs/reference/layout.md` current when adding a top-level script.
- Offline tests cannot prove a systemd unit works on a cluster. Report that
  limitation and the required re-arming procedure for unit changes.
- Commit subjects are `component: lowercase summary`; bodies explain why in
  prose wrapped at 72 columns. Summarize changes, checks and remaining limits
  for the reviewer. Never claim deployment or validation you did not perform.

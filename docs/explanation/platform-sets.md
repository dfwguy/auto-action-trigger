# Platform sets are directories, not files

`JOBS`, `HEALTHCHECKS` and `PARSERS` each name a subdirectory, and all three
default to `nvl72`. `PARSERS` also ships `spectrum-x`, whose `verdict.sh`
differs from nvl72's only in the NCCL net plugin name the `-nonvlink` pair
requires. `JOBS` ships three directories beyond `nvl72` itself: `b300-spx` and
`nvl72-spx` are different node shapes on the same Spectrum-X fabric, so both
set `PARSERS=spectrum-x`; `b300` is `b300-spx`'s node shape back on
InfiniBand, so it sets `PARSERS=nvl72` instead. None of the three needs a
parser of its own. The values and the paths they produce are in
[reference/settings.md#which-set-of-things-to-run](../reference/settings.md#which-set-of-things-to-run).

## Three variables rather than one `PLATFORM`

They are separate because they do not have to move together. A site can run the
nvl72 job set against a health-check set trimmed for its hardware, and a new
platform usually starts by reusing the existing parsers. Collapsing them into
one name would make every one of those a fork of all three.

## One place builds the paths

`settings.sh` joins each name to the bringup root and leaves `JOBS_DIR`,
`HEALTHCHECKS_DIR` and `PARSERS_DIR` set, so no script has to remember which
variable indexes which directory. That is the only place those joins happen.
Nothing else may rebuild one by hand from `$JOBS` — a second copy of the join is
a second thing to update when the layout moves, and it will be the one that is
missed.

They are set rather than exported, like everything else in `settings.sh`: this
file is sourced by every check runner, status check and container build in the
tree, and an export would put them into the environment of all of them.

## A name that resolves to nothing

This is the failure mode the whole arrangement is designed against. The natural
way to write each of these consumers is a loop, and a loop over a directory that
is not there finds nothing and says nothing — per node, per cycle, silently. It
is indistinguishable from a cluster with no work to do, which is the condition
[Silence is the enemy](architecture.md#silence-is-the-enemy) exists to rule out.

So each consumer checks the path and writes a reason instead:

| Consumer | On a missing path |
|---|---|
| `node_health.sh` | `ERROR: no health check set at <dir>`, before the loop over `[0-9]*.sh` |
| `launch_job.sh` | traces `EXIT: <dir>/verdict.sh is missing -- it carries the pass/fail rule`, and submits nothing |
| `report_job-status.sh`, `report_benchmarks.sh` | the same `verdict.sh` check, to stderr |
| `check_trigger-debug.sh` | reports all three, each name with the directory it resolved to; flags one that does not exist, and one that exists but is empty |

The same rule applies one level down, to the names *inside* these directories: a
benchmark listed in `BENCHMARKS` with no matching `.sbatch` is skipped with a
line in the trace, not in silence. Prefer an explicit check and a written reason
over a loop that finds no matches.

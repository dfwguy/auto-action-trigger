# A verdict is derived, and the cache does not change that

The framework never stores a verdict. Every cell of every report is judged from
the result file on each read, by `parsers/$PARSERS/verdict.sh`, so tightening a
gate re-judges results already on disk.

That is the property everything else here protects. Where the gates themselves
live and how they decide is
[judging-benchmarks.md](judging-benchmarks.md).

## Why it is derived rather than recorded

Each `.sbatch` used to judge itself and write `DONE` into its own result file,
and the sequencer skipped anything already marked. That froze the judgement at
the moment the job ran. When the `-nonvlink` jobs turned out to be falling back
to TCP, the fix was correct and deployed and **structurally unable to re-examine
a single one of the results it was written for** — every one of them carried a
`DONE` written under the old rule.

Deriving instead means a gate change is retroactive by construction. It also
means a job that passes is skipped at submit time on the strength of a fresh
judgement rather than a stale marker.

## How a report is produced

Both reports get their cells from `verdict-scan.sh`, which judges every
`(node, column)` pair and writes one row per cell. `report_job-status.sh` ignores the
metric field, `report_benchmarks.sh` ignores the reason; neither walks the fleet
itself.

A report is therefore tens of thousands of independent judgements, and each one
used to fork a handful of `grep`s. Reading every result file on a large cluster
takes under a second; the cost was the process churn and the fact that one shell
did all of it in sequence. So the walk is chunked across `SCAN_JOBS` workers,
and the per-cell path forks as little as it can, any saving there being
multiplied by every cell on the cluster.

`verdict-scan.sh` is 644 and both sourced *and* run — sourced by the reports for
`scan_fleet()`, run by its own `xargs` as the worker, the same arrangement as
`node_health.sh` running each health check with `bash "$check_file"`. It is not
a command anyone invokes.

Two details in that file are easy to "fix" into a bug:

- **Rows are separated by ASCII US (`0x1f`), not a tab.** `read` splits on IFS
  but also collapses runs of it when IFS holds whitespace, so with a tab a row
  with an empty reason and a metric — every passing cell that produced a number
  — delivers the metric into the reason's variable and blanks the metric. The
  report then prints `DONE` in a column that has a figure for it, which reads
  like a broken gate and is one line of the reader.
- **Each row is written with a single `printf`.** Workers share one stdout, and
  on Linux a write under `PIPE_BUF` is atomic while a field-at-a-time `printf`
  is not.

The scan runs in child processes, so nothing it does can build state in the
calling shell. A caller wanting a per-node roll-up folds the rows itself.

## The verdict cache

Judged verdicts are kept in `results/.result_cache.<mode>`, one file per mode
because the two reports ask different questions of the same files. A repeat run
goes from minutes to about a second on a large fleet.

This is the only thing in the tree that comes near storing a judgement, and what
makes it legitimate is what is in the key:

- **The gate.** `verdict.sh` and `verdict-scan.sh` are hashed in, and every
  `VERDICT_MIN_PEAK_BW_*` and `VERDICT_MAX_STEP_MS_*` is added by name and value, so editing a floor
  invalidates every entry at once and the fleet is re-judged. Floors move as the
  platform is learned, and the bandwidth ones live in `SETTINGS`
  ([reference/settings.md#benchmark-pass-floors](../reference/settings.md#benchmark-pass-floors))
  where hashing the parser cannot see them; without that, re-flooring a job
  would change nothing and no output would say so.
- **Every result file under the node** — name, size and mtime, archives
  included. A new, changed or deleted result re-judges that node and no other.
  Size alone would miss a rewrite of equal length, so mtime is in there too.

Validity is per file, which is what makes the check one `find` for the fleet
rather than a read of every byte. Replay is per node, which keeps the rules
about which file feeds which cell — the archive fallback especially — in
`_scan_node()` rather than restated in awk where the two could drift.

Two things change an answer with no file changing, and both are kept out of the
cache rather than checked by it:

- A node with a job on it now. `RUNNING` comes from `squeue`, which is live
  state, and its files are being written as the report runs.
- **That same node's rows are never written down either.** Once the job ends,
  nothing on disk would invalidate a cached `RUNNING`, and the report would call
  a finished job live.

**Anything added to a verdict that is not a pure function of the result file and
the gate does not belong in a cached row.** `tests/scan-cache-test.sh` holds all
of this; a stale hit is silent, so that suite is what stands between a wrong key
and a clean-looking report of a broken cluster.

The files are derived and disposable:

```bash
rm -f results/.result_cache.*      # rebuilt on the next run
./report_job-status.sh --no-cache       # or bypass it for one run
./report_benchmarks.sh --no-cache
```

Reach for either when you suspect the *cache* rather than the gate — a restore
that reset mtimes, a clock that moved backwards. If a `--no-cache` run disagrees
with a cached one, that is a bug worth reporting, not a cache worth clearing.

## A shared cache file

`.result_cache.<mode>` lives under `results/`, which is not one account's
directory — any operator with access can run `report_job-status.sh` or
`report_benchmarks.sh` under their own login, not just `$JOB_USER`. Whoever rebuilds
the cache becomes its owner, because `scan_fleet()` replaces it by `mv` rather
than editing it in place — the rename is what lets a reader see one whole cache
or the other and never a half-written one.

A plain `mv` leaves the new file at whatever mode the writer's `umask` gives a
freshly created one, ordinarily `644` — owner read-write, everyone else
read-only. The next operator to run a report, in a different account, then
fails the write-preflight (`: >> "$cache"`) that opens the *existing* file
directly, and falls back to judging the whole fleet from scratch every time,
silently losing the speedup the cache exists for. `scan_fleet()` now `chmod
664`s the replacement before the rename, so the file stays writable by the
whole group regardless of whose account last rebuilt it or what their `umask`
was. This assumes report-runners share a group on `results/` — true of every
site so far, since arming and file ownership already assume one.

## A column between two attempts

`launch_job.sh` archives a result before it submits the next attempt, so for the
whole time a job sits in the queue the column has no current file at all. Slurm
creates `results/<node>/<col>.txt` at job *start* — `sbatch --output` points at
it — so "no file" and "running" are different states, and the gap is real:
minutes on an idle cluster, hours behind a busy queue or a drain.

That gap used to report as `RETRY`, one status covering both kinds of archive.
It read as a transient — something in progress, nothing to act on — and that is
true of one of the two and false of the other. A column sitting in the gap
because its last attempt was *rejected* is a failing column. Nothing about the
node changed when `launch_job.sh` renamed the file; only the report did, and a
node with a failure on disk dropped out of the `FAIL` list on the strength of a
`mv`. The confusion it produced is the reason it is gone.

So the archive that fills the gap decides the status, and there are two:

| Archive | Status | Because |
|---|---|---|
| `<col>.fail<N>.txt` | `FAIL` | the attempt was rejected; the reason is that attempt's, plus *a re-run is queued* |
| `<col>.prev<N>.txt` | `RERUNNING` | `launch_job.sh --all` archived a **passing** result and asked for it again |

One case crosses over. A `.fail<N>.txt` that passes the gate *as it stands now*
is not a failure — the floor was lowered, or the parser was fixed, between the
rejection and the report. It reports `RERUNNING`, with the reason
`prior attempt passes the current gate`, rather than a `FAIL` no file on disk
supports.

`NOT_RUN` keeps its one meaning throughout: no attempt has ever been made.
Reports that pass `SCAN_ARCHIVES=0` — `report_benchmarks.sh` and `check_next-run.sh` — do
not look at archives at all and read the gap as `NOT_RUN`, which is the same
answer for what they ask: not passing.

## Where `RUNNING` comes from

`RUNNING` is not written by `verdict.sh`, which sees only the result file and
reports a marker-less one as `INCOMPLETE`. That is right for `launch_job.sh`,
which judges a node only after it knows nothing is queued or running on it.
`report_job-status.sh` has no such guard — `sbatch --output` points at the result
file, so a benchmark that is mid-run is a partial file with no marker. It
resolves the ambiguity with one cluster-wide `squeue`, matching the
`bringup-<node>` and `burnin-<node>` job names, and reclassifies the column that
live job is writing. Without `squeue` on `PATH` it says so on stderr and both
states report as `INCOMPLETE`.

`squeue` names the node but not the benchmark, so the live column is the newest
result file in `results/<node>/`. `sbatch` truncates `--output` at job start and
only one job of ours is ever out, so that file is newest even before its first
byte, and every other marker-less column on the node really was left by a job
that has exited.

"Newest result file" is matched by name against `BENCHMARKS` and `BURNIN`, not
taken as "the newest `.txt` that is not an archive". The node directory also
holds `quick-view.txt`, which `launch_job.sh` rewrites every cycle: read as a
result it is newest almost always, no column ever matches it, and every running
job on the fleet reports `INCOMPLETE -- job died before finishing`. Both lists
are used rather than the `-t` selection, because the newest file among a subset
of the columns is not the one being written. `tests/scan-cache-test.sh` keeps a
`quick-view.txt` in its fixture tree for this.

# Reset results for a node, or for everything

```bash
bash admin_purge-node-benchmarks.sh node001 "node[002-004]"   # one or more nodes/nodelists
mv results results.$(date +%F)       # everything, kept
rm -rf results                       # everything, gone
```

Safe at any time — the tree is recreated on the next agent
cycle. See
[reference/layout.md#result-path-ownership](../reference/layout.md#result-path-ownership)
for why ownership matters and how to fix a tree immediately rather than waiting.

## What a purge removes

`admin_purge-node-benchmarks.sh` removes `results/<node>` outright, per node: the current
result file for every benchmark, every `.fail<N>.txt` and `.prev<N>.txt`
archive, `quick-view.txt`, `trigger.log` and `recover.log`. The node is then
`NOT_RUN` in every column with no history behind it, and the next sweep re-runs
the full benchmark set from scratch.

Arguments are node names or nodelists (`node00[1-18]`), expanded through
`scontrol show hostnames`, and several may be given at once; a name with no
results directory is reported and skipped rather than passed silently.

It also resets the recovery rate limit, since the log the cap is counted from
goes with the directory.

## When to do it

After a hardware change — a swapped GPU, a reseated cable, new firmware — where
the results on disk describe a machine that no longer exists and would otherwise
keep a node in `FAIL` against failures it has already grown out of.

## What it does not touch

The health side: `logs/<node>` and the `valid-config/default` baseline survive,
so a purge re-runs the benchmarks and changes nothing about what
`node_health.sh` concluded. To redo that half:

```bash
bash report_health.sh --refresh node001
```

## Do not purge a node with a benchmark in flight

`sbatch --output` is already holding that file open, so the running job writes
into a directory that no longer exists and the result never appears — which
reads afterwards as a job that ran and produced nothing. Check first, or purge
after the sweep is idle:

```bash
squeue -h -n bringup-<node>
```

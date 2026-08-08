# Find the slow node when nothing has failed

Every benchmark passes and the fleet still feels wrong, or you want to catch the
node that is about to fail before it does. Verdicts will not help you here —
they are pass/fail against a floor, and a node can sit just above the floor for
weeks. The numbers will.

## 1. Read the spread, not the values

```bash
bash daily-report.sh > /dev/null
```

The summary is on stderr, so that discards the table and keeps it. Rows come
back raw tab-separated rather than aligned — the report aligns only for TSV at a
terminal, and redirecting stdout is not that. Drop the redirect to read it
aligned with the table above it.

The block you want is `job (metric)`:

```
job (metric)                    n     min   median    mean     max
allreduce (busbw GB/s)        254   612.4    701.2   699.8   706.3
allreduce-nonvlink (GB/s)     254    32.4     98.1    96.7    99.4
```

**The spread across nominally identical nodes is the finding, not any single
value.** A fleet where every node lands in a narrow band is healthy even before
you have confirmed the band is right. A fleet scattered across a 3× range has
something wrong regardless of how good the best node looks.

Two things to read off those rows immediately:

- **`min` against `median`.** These are the same hardware running the same job.
  A `min` well below the `median` is a node worth naming — in the row above,
  `allreduce` at 612 against a 701 median is a 13% outlier that is passing the
  683 floor nowhere near comfortably.
- **`mean` against `median`.** Close together means a tight distribution with no
  outliers pulling it. A `mean` dragged below the `median` says a small number
  of nodes are much worse than the rest, which is exactly the population you are
  looking for.

**Failing runs are included in these statistics**, deliberately — so `min` is
the worst node on the cluster, not the worst node that passed.

## 2. Name the outlier

The summary gives you a number, not a node. Sort the table to find it:

```bash
bash daily-report.sh | sort -t$'\t' -k3 -g | head -10
```

Column 3 is the first benchmark column (node, slurm state, then the jobs in
`BENCHMARKS` order). Count across the header to pick the column you want:

```bash
bash daily-report.sh | head -1 | tr '\t' '\n' | cat -n
```

Then sort on that column number. Cells holding a status word rather than a
number sort to one end under `-g`, which is usually what you want — they are the
nodes with no measurement at all.

Rows come back tab separated when piped, which is why `sort -t$'\t'` works. The
aligned layout you see at a terminal is for reading only.

## 3. Confirm it is the node and not the run

One low reading is not a finding. Before escalating, check it repeats:

```bash
ls results/<node>/allreduce*.txt
```

Archives (`.fail<N>.txt`, `.prev<N>.txt`) are the attempt history. If earlier
attempts were also slow, the node is slow. If only this one was, you may have
caught contention or a transient.

To take a fresh measurement without waiting for the hourly cadence:

```bash
pdsh -R ssh -w <node> '/home/cmods/bringup/actions/launch_job.sh -t allreduce -v'
```

`--test` runs the job outside the configured lists, drains nothing, and leaves
`quick-view.txt` alone — see
[run-a-job-by-hand.md](run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list).

## 4. Ask which GPU, not just which node

For a node that is slow rather than broken, the two LLM jobs separate the
questions. `llm-pretrain` runs one 4-way data-parallel job across the tray;
`llm-pretrain-solo` runs four independent single-GPU copies with no collectives
at all.

Because every GPU does identical work in the solo job, **an outlier step time
names a slow device rather than a slow node**:

```
per-GPU step times disagree -- spread above 0.05
cov 0.074, slowest gpu 2 at 0.4740 vs 0.4202 mean per step
```

Note that `VERDICT_MAX_COV_LLM_SOLO` ships as `0`, which **skips** the spread
check entirely — the house convention for a floor with no established band. If
that job is passing everywhere, check whether the gate is actually running
before trusting it. See
[explanation/llmb.md#judging-the-four-step-times](../explanation/llmb.md#judging-the-four-step-times).

## 5. Know which direction the finding points

Before opening a ticket on hardware, apply the rule that has cost the most time
here in both directions:

| Shape | Almost always |
|---|---|
| One node below the median | That node |
| A handful, scattered | Hardware, several instances |
| One rack | Rack-level: a switch, a power domain, an IMEX domain, cabling |
| **Every node far below a floor** | **The floor, or the platform** |

The `-nonvlink` floors are the live example: 93 and 83 GB/s, measured on a
**100 GB/s compute plane**. Every IB-scope result captured as a fixture sits
below them. On a site with a different link speed, every node lands under the
floor and none of them is faulty.

So: a handful of nodes under a floor is a fabric problem. Every node far below
it is the floor being wrong, and the first thing to check is the compute plane's
link speed rather than any node. See
[explanation/judging-benchmarks.md#floors-are-a-property-of-the-hardware](../explanation/judging-benchmarks.md#floors-are-a-property-of-the-hardware).

## 6. Compare a rack against the fleet

The summary describes **the nodes that matched and nothing else**, so a filtered
report's median is that rack's median rather than the fleet's:

```bash
bash daily-report.sh > /dev/null                      # fleet
bash daily-report.sh ink50-dh01-h20 > /dev/null       # one rack
```

The `nodes` count in the first summary block is what says how many nodes the
statistics were taken over — check it, because a filtered report that matched
three nodes has a median you should not draw conclusions from.

Comparing the two medians is the fastest way to separate "this rack is slow"
from "this cluster is slow".

## What the numbers cannot tell you

A tight band at the wrong absolute value looks perfect here. Every floor in this
tree is an **observed** band off known-good hardware rather than a published
figure, so a fleet that agrees with itself and disagrees with the world is a
case these reports cannot detect. That is what the fixtures and the testing plan
are for.

Both LLM jobs also run below their recipe's characterised scale, so their
numbers compare nodes to each other and are **not** comparable to NVIDIA's
published figures — see
[explanation/llmb.md#running-below-the-characterised-scale](../explanation/llmb.md#running-below-the-characterised-scale).

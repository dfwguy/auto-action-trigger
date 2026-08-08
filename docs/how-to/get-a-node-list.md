# Get a node list you can act on

You have a report and you need the nodes out of it, in a form `pdsh -w`,
`scancel`, `scontrol` or `health-check.sh --refresh` will take. Both roll-ups exist
for this and neither is the default output.

## From benchmark status

```bash
bash status-check.sh -s
```

One compressed node list per status, reasons dropped. The default report answers
*why*; `-s` answers *which nodes*.

```
SUMMARY — judged on all 8 active columns

FAIL — 2 nodes (ran and was rejected by the current gate)
ink50-dh01-h20-[03,17]
```

Ranges rather than a bare comma list, via `scontrol show hostlistsorted`, so it
pastes straight into the tools below. If `scontrol` is unavailable it falls back
to the plain list, which most of the same tools still accept.

**Every node appears in exactly one list**, under the worst status it holds
across the selected tests:

```
FAIL > INCOMPLETE > RETRY > NOT_RUN > RUNNING > DONE
```

The lists are therefore disjoint and a node cannot be acted on twice. It also
means **`DONE` there means every selected test passes**, not that some did.

## Scope it to the test you are acting on

This is the part to get right before pasting anything anywhere:

```bash
bash status-check.sh -s -t allreduce
```

The header changes to name what the roll-up covers:

```
SUMMARY — judged on: allreduce
```

**A `-t`-scoped list that does not say so is one paste away from draining nodes
over a test they were never judged on.** The header is there so an exported list
carries its own scope; keep it when you paste the list somewhere else.

Remember `-t` matches as written with no implicit `*` — `-t allreduce` will not
pull in `allreduce-nonvlink`. Spell out `-t 'allreduce*'` if you want both.

Narrow by node at the same time:

```bash
bash status-check.sh -s -t allreduce ink50-dh01-h20
```

## From health state

```bash
bash health-check.sh --summary
```

Four buckets, every node in exactly one, adding up to the node count:
`PASSING`, `FAILING HEALTH CHECKS`, `NOT CHECKED`, `OTHER DRAINS`.

`NOT CHECKED` is the one to reach for first at a new site — those are available
nodes with no `logs/<node>`, meaning the checks have never run there:

```bash
bash health-check.sh --refresh 'ink50-dh01-h15-[11-14]'
```

`OTHER DRAINS` is **not** a health verdict. Those nodes are down or drained for
a reason `node_health.sh` did not write, so Slurm carries no health result for
them either way. Do not treat that bucket as a list of bad nodes.

For the grouped view, the default report already ends by naming one node per
group to diagnose — one is enough, since the rest of the group failed the same
checks.

## Feeding the list to something

Take the list from either roll-up and use it directly:

```bash
# re-run the health checks
bash health-check.sh --refresh 'ink50-dh01-h20-[03,17]'

# clear results and start that node's benchmarks over
bash single-node-purge.sh 'ink50-dh01-h20-[03,17]'

# run something on each node
pdsh -w 'ink50-dh01-h20-[03,17]' 'nvidia-smi -L'

# resume them
scontrol update nodename='ink50-dh01-h20-[03,17]' state=RESUME

# force a sweep now
pdsh -w 'ink50-dh01-h20-[03,17]' '/home/cmods/bringup/actions/launch_job.sh -f -v'
```

**Quote the list.** The `[03,17]` range syntax contains glob characters, and an
unquoted list is expanded by your shell against the current directory before the
tool ever sees it — which usually produces the literal string anyway, and
occasionally does not.

## Before you act on a fleet-wide list

Two checks worth the extra command:

**Is the report current?** Both roll-ups print a banner on stderr when the thing
that produces them is paused — `PAUSE_JOBS` for `status-check.sh`,
`PAUSE_HEALTH_CHECKS` for `health-check.sh`. A paused report cannot change and
looks exactly like a cluster that has settled. The banner is on stderr
deliberately, so it survives `-s` being piped and cannot land inside a node list
you are about to paste.

**Is the failure real, or is it the gate?** A handful of nodes in a `FAIL`
bucket is a hardware finding. Every node in it is usually the rule, the floor,
or a missing image — see
[diagnose-a-failed-node.md](diagnose-a-failed-node.md#4-when-everything-fails-at-once).
Acting on the second case drains a working fleet.

For anything cancelling jobs across the fleet, `kill-jobs.sh -n` prints what it
would cancel and changes nothing. Use it — the patterns are shell globs typed
under time pressure, and a `*` in the wrong place is the difference between one
rack and the cluster. See [pause-and-resume.md](pause-and-resume.md).

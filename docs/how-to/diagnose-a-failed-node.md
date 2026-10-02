# Diagnose a failed node

Reading a failure back to the device that caused it. This is the *hardware*
direction — the opposite one, where nothing is running at all and no results are
being produced, is
[diagnose-nothing-running.md](diagnose-nothing-running.md), and you should rule
it out first: a chain that has stopped producing results looks exactly like a
fleet that has stopped failing.

The tables this procedure looks things up in are
[reference/reasons.md](../reference/reasons.md).

To see every node in this state at once, with its drain reason, its failing
health checks and — for a node Slurm drained with `Prolog error` — the check
that actually failed, start from `report_overall.sh --details`:
[reference/scripts.md](../reference/scripts.md#report_overallsh--the-fleet-in-one-line-per-node).

## 1. Count the nodes before reading the failure

The same reason string means opposite things at different scales, and this is
the single most common way time gets lost here.

| Shape | What it almost always is | Start at |
|-------|--------------------------|----------|
| **One node**, everything else clean | That node's hardware | the result file itself |
| **A handful, scattered** | Hardware, several instances | `report_benchmarks.sh`, compare the numbers |
| **One rack, all of it** | Rack-level: a switch, a power domain, an IMEX domain, cabling | the rack, not the nodes |
| **Every node, all at once** | The framework, not the fleet | [step 4](#4-when-everything-fails-at-once) |

The framework fails *closed* by design: a wrong rule condemns every node and
looks precisely like a catastrophic hardware finding. `nvbandwidth` once failed
every multi-GPU node in the fleet on results that were perfect, because the rule
matched the `N/A` that every peer matrix prints down its own diagonal. **A
cluster-wide failure is a claim that all of your hardware broke simultaneously**,
which is rarely what happened.

```bash
bash report_job-status.sh -s -t <job>     # node lists per status, for the job that failed
```

## 2. Read the status word, then the result file

```bash
bash report_job-status.sh <node>
cat results/<node>/<failing-job>.txt
```

Look up the status word and the verdict reason in
[reference/reasons.md](../reference/reasons.md). The fork that matters most is
the `exit status:` line at the end of the file: non-zero is the job's own
verdict with the cause above it in the same file; zero under a `FAIL` means the
gate rejected clean output, and the reason is only in `report_job-status.sh`.

## 3. Read the number, not just the verdict

```bash
bash report_benchmarks.sh | grep <node>
```

A `-nonvlink` cell at 41 GB/s and one at 2.2 both fail the same floor and are a
slow fabric and a socket fallback respectively. The report prints the same
figure the floor is stated against.

For the `-nonvlink` pair specifically, the fastest confirmation is:

```bash
bash check_ib.sh <node>
```

See [diagnose-ib-visibility.md](diagnose-ib-visibility.md).

## 4. When everything fails at once

Work down this list before touching hardware. Each of these has produced a
whole-cluster failure that looked like a fleet-wide hardware event.

1. **The baseline is missing or wrong.** `valid-config/default` is a symlink to
   a node on *this* cluster. If it does not resolve, every check on every node
   diffs against a file that is not there. `report_health.sh` leads with
   `WARNING: no baseline` — nothing under that banner is real.
2. **The baseline node was not actually good.** Whatever node you named became
   the definition of correct BIOS, kernel params, IMEX and NVLink for the whole
   fleet.
3. **A floor is wrong for this platform.** The `-nonvlink` floors, 93 and 83
   GB/s, were measured on a 100 GB/s compute plane, and every IB-scope result
   captured as a fixture sits below them. A handful of nodes under a floor is a
   finding; every node far below it is the floor — check the link speed first.
4. **The gate is matching the tool's healthy output.** The failure mode that
   cost the most so far. Check whether the string being matched appears in a
   *passing* run — both the `nvbandwidth` diagonal case and the
   `Using network Socket` case are written up in
   [explanation/judging-benchmarks.md](../explanation/judging-benchmarks.md),
   with fixtures for both.
5. **A missing image.** A job whose container was never built fails identically
   on every node. `./build_containers.sh -l` is the check.
6. **The job does not apply to this platform.** `nvsm` is DGX-only and drains a
   non-DGX cluster for a tool that was never going to run.
7. **A name that resolves to nothing.** A benchmark in `BENCHMARKS` with no
   matching `.sbatch` is skipped, per node, per cycle — the trace says so, but
   nothing else will.

## Worked examples

**Every `-nonvlink` cell reads 30-something, floor is 43.** Not 200 bad HCAs.
Item 3 above — read a full `report_benchmarks.sh` before acting on the drains. If the
spread is tight and the transport is right (`via NET/IB`, not Socket), the floor
is the thing that is wrong.

**One node fails `allreduce-forcesharp`, passes `allreduce`.** That pair exists
to separate two questions. `allreduce` asks whether the collective works;
`allreduce-forcesharp` pins `NCCL_ALGO=NVLS` and asks whether the NVSwitch
offload is what is doing it. A node that passes the first and fails the second
ran the collective on a GPU-side fallback — SHARP never happened. Expect the
NCCL init error in full in the result file. If this starts failing *fleet-wide
right after an image change*, suspect `NCCL_ALGO`: which algorithms exist behind
that name is a property of the NCCL build, not of the fabric.

**One rack fails the IMEX checks, other racks clean.** Rack-scoped by
construction. Look at the IMEX domain and that rack's membership, not at 18
individual nodes.

**A node passes everything, then fails one job with `run error` and
`CANCELLED AT ... DUE TO TIME LIMIT`.** The step hit its limit. That is usually
a real finding — a node doing its work several times slower than its peers — and
it is deliberately reported as a failure rather than as a node that mysteriously
stopped.

**A node shows `INCOMPLETE` on every column, `NOT_RUN` before that.** Suspect
`results/` ownership before the node: a root-owned result directory means
`sbatch` returns a job id, Slurm schedules it, and it dies at startup with
nowhere to write. See
[reference/layout.md#result-path-ownership](../reference/layout.md#result-path-ownership).

## Before escalating

Collect, per affected node:

```bash
bash report_job-status.sh <node>                       # what the gates say
bash report_benchmarks.sh | grep <node>                # the numbers, and Slurm state
bash report_health.sh --diff <node>                # health-check diffs vs baseline
sinfo -R -n <node>                                # the drain reason verbatim
tail -40 results/<node>/trigger.log               # what the sequencer decided
cat results/<node>/<failing-job>.txt              # the raw output, whole file
```

Send the **whole result file**, not the matched line. Most of the expensive
mistakes in this system's history were cases where the matched line was
misleading and the surrounding context was not.

State the scale explicitly — one node, a rack, or the fleet. As step 1 says, the
same string means different things at different scales, and it is the first
thing anyone receiving the report will ask.

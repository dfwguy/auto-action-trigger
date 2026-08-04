# Troubleshooting the system under test

For reading a failure back to the device that caused it. It starts from what
`status-check.sh`, `daily-report.sh` and a result file actually say, and works
toward which component to look at.

This is the *hardware* direction. The opposite direction — nothing is running at
all, no results are being produced — is
[operations.md](operations.md#debugging-nothing-is-running), and you should rule
it out first, because a chain that has stopped producing results looks exactly
like a fleet that has stopped failing.

## First: is this the fleet, or is this a node?

Before reading any individual failure, count how many nodes have it. The same
reason string means opposite things at different scales, and this is the single
most common way time gets lost here.

| Shape | What it almost always is | Start at |
|-------|--------------------------|----------|
| **One node**, everything else clean | That node's hardware | the result file itself |
| **A handful, scattered** | Hardware, several instances | `daily-report.sh`, compare the numbers |
| **One rack, all of it** | Rack-level: a switch, a power domain, an IMEX domain, cabling | the rack, not the nodes |
| **Every node, all at once** | The framework, not the fleet — a baseline, a floor, a threshold, a missing image, a platform mismatch | the config, see [below](#when-everything-fails-at-once) |

The framework fails *closed* by design: a wrong rule condemns every node and
looks precisely like a catastrophic hardware finding. `nvbandwidth` once failed
every multi-GPU node in the fleet on results that were perfect, because the rule
matched the `N/A` that every peer matrix prints down its own diagonal. A
cluster-wide failure is a claim that all of your hardware broke simultaneously,
which is rarely what happened.

## From a status word to a next step

`status-check.sh` gives you one of six words. Only two of them are about the
device at all.

| Status | About the device? | Next step |
|--------|-------------------|-----------|
| `FAIL` | **Yes, usually** | Read `results/<node>/<job>.txt`. Find the `exit status:` line — see below |
| `INCOMPLETE` | **Yes** | The job died mid-run: crash, walltime, OOM, node reset. No end marker. Check `dmesg` and the Slurm accounting for the job |
| `RETRY` | Not yet | An attempt was archived and a re-run is queued. The reason shown is why the *previous* attempt was rejected; look at `.fail<N>.txt` |
| `NOT_RUN` | No | Never attempted. Read the trace — [trigger-log.sh](sequencer.md#every-line-the-trace-can-write) |
| `RUNNING` | No | In flight, nothing to judge yet |
| `DONE` | No | The gate accepted it. Note this is not "the number is good", it is "the number cleared the floor" |

### `exit status:` says who decided a `FAIL`

Every result file ends with two lines, and the first one is the fork:

```
exit status: 0
FAIL
```

- **Non-zero** — the job's own verdict. `srun` returned it, the workload failed
  or was killed, and the diagnosis is somewhere above in the same file.
- **Zero, under a `FAIL`** — the workload ran clean and the *gate* rejected the
  output. Nothing in the file says why, because the gate runs at status-check
  time and writes nothing back. The reason is in `status-check.sh`.

That distinction exists because the two have completely different fixes, and
without the line they are indistinguishable in the file.

## From a verdict reason to a device

These are the strings `status-check.sh` prints after a `FAIL`. Grouped by what
they implicate.

### The collective did not go where it was supposed to

| Reason | What it means about the device |
|--------|-------------------------------|
| `collective carried over TCP` | NCCL found no usable HCA and fell back to sockets over `bond0`. The run is correct, complete and worthless. Not a fabric performance problem — a fabric *visibility* problem. Follow the chain below |
| `collective left NVLink for the network` | An NVLink-scope job put a channel on the network. NVLink is degraded or absent on this node; the collective escaped to a path it should never have used |
| `no HCA visible inside the container` | The host may be fine. The container got a fresh `/dev` without the HCAs bind-mounted |
| `no IB device visible to NCCL` | `NET/IB : No device found.` — the IB plugin never loaded |
| `no compute-plane HCA` | Host-side discovery found nothing to pin `NCCL_IB_HCA` to |
| `peak busbw below floor <n> GB/s` | It went the right way, but slowly. This is a *performance* finding — the transport was correct |

**The order matters.** These checks are deliberately arranged by causation, not
by severity, and the first to fire is the one reported. The chain runs:

```
container gets a fresh /dev
  → container cannot see the HCAs
    → NET/IB : No device found.
      → IB plugin fails to load
        → fallback to Socket
          → every channel over bond0   ← "collective carried over TCP"
```

Reading that chain backwards is how weeks get spent looking at a fabric when the
fault is a missing bind mount. If you see `collective carried over TCP`
fleet-wide, do not go to the fabric — go to the container. And note that
checking by hand over `ssh` puts you on the *host*, which will show a perfectly
healthy HCA list no matter how broken the container's view is. Both lists are
printed into every result file for exactly this reason. See
[benchmarks.md](benchmarks.md#host-hcas-are-not-container-hcas).

### Bandwidth, and what a number means

A `-nonvlink` cell at 41 GB/s and one at 2.2 GB/s both fail the same 80 GB/s
floor, and they are entirely different findings: the first is a slow fabric, the
second is a socket fallback. Always read the number, not just the verdict.
`daily-report.sh` prints the same figure the floor is stated against, so the
comparison is direct.

| Reason | Implicates |
|--------|-----------|
| `measured <n> GB/s at the largest message size` | Read against the floor and against the fleet's spread |
| `bandwidth unstable -- coefficient of variation above <n>` | Run-to-run instability, not a low number. Thermal throttling, a marginal link, contention |
| `missing peer transfer -- N/A off the matrix diagonal` | A GPU pair that cannot talk. `N/A` on the diagonal is normal — off it is a dead path |
| `slowest GPU measured <n> TFLOPS` | One GPU below its siblings — the per-GPU spread is the finding |

### Memory, GPUs and the node itself

| Reason | Implicates |
|--------|-----------|
| `memory miscompare or hardware error` | DRAM. A miscompare is a bit that came back wrong — treat as a hardware finding, not a flake |
| `memtester reported a bad address` | A specific failing address. DIMM-level |
| `dcgmi subtest failed: <name>` | The named subtest says which GPU subsystem. The most direct GPU-level signal here |
| `nvsm reported a health fault` | System-level: thermal, power, or a component NVSM tracks |
| `ranks disagree on rackGuid` | Ranks think they are in different racks — MNNVL domain or cabling |
| `interface has no IPv4 address` | Config, not hardware. The NIC named in the job never came up |
| `could not reach the ethr server` | The `ethr` server host in the job file, not the node under test |

### Reasons that are about the run, not the device

| Reason | Meaning |
|--------|---------|
| `run error` | Matched `VERDICT_RUN_ERRORS` — a Slurm cancellation, an `srun: error`, a segfault, a step killed on the clock. A step cancelled `DUE TO TIME LIMIT` is a real finding: the node ran its work several times slower than its peers |
| `no end marker -- job died before finishing` | The batch script itself was killed, usually the job walltime rather than the step limit |
| `empty result file` / `no result file` | Nothing was written. Frequently ownership — see [sequencer.md](sequencer.md#result-path-ownership) |
| `job reported FAIL` | Preflight, most often: the step did not receive the whole node |

## From a drain reason to a component

`sinfo -R` gives a reason; `health-check.sh` groups nodes by the *set* of checks
they failed, and `sync-check.sh <node>` diffs one node against the baseline for
each check named. One node per group is enough — the rest failed the same way.

Broad mapping from the 38 checks:

| Checks | Component |
|--------|-----------|
| `bios`, `os`, `kernel-params`, `numa`, `numa-settings` | Node configuration, not hardware. Usually a provisioning drift |
| `cpu-specs`, `cpu-freq`, `memory` | CPU and DRAM inventory and governor state |
| `nvidia-smi-ecc`, `nvlinks`, `nvlink-ber`, `nvidia-smi-p2p-*` | GPU and NVLink. `nvlink-ber` is a link-quality signal — a marginal link before it fails outright |
| `ib-status`, `ib-down`, `ib-link`, `ib-pkey`, `ib-firmware` | The IB HCAs and fabric. `ib-firmware` and `ib-pkey` are fleet-consistency checks: they fail on the node that is *different*, which may be the correct one |
| `pcie-lnk-stat`, `pcie-acs`, `pcie-mrrs` | PCIe topology and negotiation. `pcie-lnk-stat` catches a device that trained at x8 where x16 was ordered |
| `iface`, `bond` | Host networking |
| `imex-channels`, `imex-profile`, `imex-service`, `imex-readiness` | Node-local IMEX. These *do* drain |
| `enroot` | Container runtime path not writable — will break every containerized job |
| `dmesg-*` | Kernel-level evidence: `xid` for GPU faults, `hw_err` for machine checks, `mlx5_core` for HCA health, `knvlink` for NVLink discovery |

Three checks — `nvidia-smi-cuuid`, `imex-node-config`, `imex-status` — are
informational and can never drain a node, because they compare something
per-rack against a cluster-wide baseline. Read them by hand with
`sync-check.sh --all <node>`; they are often the fastest confirmation that a
node is cabled into the wrong rack. See
[health-checks.md](health-checks.md#informational-checks).

Not every drain is a health check. `slurm-recovery.sh` sorts drains into four
classes and **an operator drain is never cleared by anything in this tree** —
see [operations.md](operations.md#drains-that-clear-themselves).

## When everything fails at once

Work down this list before touching hardware. Each of these has produced a
whole-cluster failure that looked like a fleet-wide hardware event.

1. **The baseline is missing or wrong.** `valid-config/default` is a symlink to a
   node on *this* cluster. If it does not resolve, every check on every node
   diffs against a file that is not there. `health-check.sh` leads with
   `WARNING: no baseline` — nothing under that banner is real.
2. **The baseline node was not actually good.** Whatever node you named became
   the definition of correct BIOS, kernel params, IMEX and NVLink for the whole
   fleet.
3. **A floor is wrong for this platform.** The `-nonvlink` floor of 80 GB/s is a
   spec figure for a 100 GB/s compute plane, not one read off a known-good run
   here, and it sits above every IB-scope result captured so far. A handful of
   nodes under a floor is a finding; every node far below it is the floor —
   check the link speed first, since 43 is the same figure at 50 GB/s.
4. **The gate is matching the tool's healthy output.** The failure mode that cost
   the most so far. Check whether the string being matched appears in a *passing*
   run — `benchmarks.md` has both the `nvbandwidth` diagonal case and the
   `Using network Socket` case written up, with fixtures for both.
5. **A missing image.** A job whose container was never built fails identically
   on every node. `./build_containers.sh -l` is the check.
6. **The job does not apply to this platform.** `nvsm` is DGX-only and drains a
   non-DGX cluster for a tool that was never going to run.
7. **A name that resolves to nothing.** A benchmark in `BENCHMARKS` with no
   matching `.sbatch` is skipped in silence, per node, per cycle.

## Worked examples

**Every `-nonvlink` cell reads 30-something, floor is 43.** Not 200 bad HCAs.
Item 3 above — read a full `daily-report.sh` before acting on the drains. If the
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
`CANCELLED AT ... DUE TO TIME LIMIT`.** The step hit its limit. That is usually a
real finding — a node doing its work several times slower than its peers — and
it is deliberately reported as a failure rather than as a node that mysteriously
stopped.

**A node shows `INCOMPLETE` on every column, `NOT_RUN` before that.** Suspect
`results/` ownership before the node: a root-owned result directory means
`sbatch` returns a job id, Slurm schedules it, and it dies at startup with
nowhere to write.

## Before escalating

Collect, per affected node:

```bash
bash status-check.sh <node>                       # what the gates say
bash daily-report.sh | grep <node>                # the numbers, and Slurm state
bash sync-check.sh <node>                         # health-check diffs vs baseline
sinfo -R -n <node>                                # the drain reason verbatim
cat results/<node>/trigger.log | tail -40         # what the sequencer decided
cat results/<node>/<failing-job>.txt              # the raw output, whole file
```

Send the **whole result file**, not the matched line. Most of the expensive
mistakes in this system's history were cases where the matched line was
misleading and the surrounding context was not.

State the scale explicitly — one node, a rack, or the fleet. As the table at the
top says, the same string means different things at different scales, and it is
the first thing anyone receiving the report will ask.

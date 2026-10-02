# Status words, verdict reasons and drain reasons

Lookup tables for reading a failure back to the device that caused it. The
procedure that uses them is
[how-to/diagnose-a-failed-node.md](../how-to/diagnose-a-failed-node.md).

## Status words

`report_job-status.sh` gives you one of six. Only two of them are about the device at
all.

| Status | About the device? | Next step |
|--------|-------------------|-----------|
| `FAIL` | **Yes, usually** | Read `results/<node>/<job>.txt`. Find the `exit status:` line. When the reason ends `a re-run is queued` there is no current file and the newest `.fail<N>.txt` is what was judged |
| `INCOMPLETE` | **Yes** | The job died mid-run: crash, walltime, OOM, node reset. No end marker. Check `dmesg` and the Slurm accounting for the job |
| `RERUNNING` | No | A **passing** result was archived and asked for again. Nothing to act on; look at `.prev<N>.txt` for what it scored last time |
| `NOT_RUN` | No | Never attempted. Read the trace — [trace-lines.md](trace-lines.md) |
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
  time and writes nothing back. The reason is in `report_job-status.sh`.

See
[explanation/judging-benchmarks.md#exit-status-says-who-decided-a-fail](../explanation/judging-benchmarks.md#exit-status-says-who-decided-a-fail).

## Verdict reasons

These are the strings `report_job-status.sh` prints after a `FAIL`.

### The collective did not go where it was supposed to

| Reason | What it means about the device |
|--------|-------------------------------|
| `collective carried over TCP` | NCCL found no usable HCA and fell back to sockets over `bond0`. The run is correct, complete and worthless. Not a fabric performance problem — a fabric *visibility* problem |
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
fleet-wide, do not go to the fabric — go to the container. See
[explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas](../explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas),
and read a live node with
[how-to/diagnose-ib-visibility.md](../how-to/diagnose-ib-visibility.md).

### Bandwidth, and what a number means

A `-nonvlink` cell at 41 GB/s and one at 2.2 GB/s both fail the same `-nonvlink`
floor, and they are entirely different findings: the first is a slow fabric, the
second is a socket fallback. **Always read the number, not just the verdict.**
`report_benchmarks.sh` prints the same figure the floor is stated against, so the
comparison is direct.

| Reason | Implicates |
|--------|-----------|
| `measured <n> GB/s at the largest message size` | Read against the floor and against the fleet's spread |
| `bandwidth unstable -- coefficient of variation above <n>` | Run-to-run instability, not a low number. Thermal throttling, a marginal link, contention |
| `missing peer transfer -- N/A off the matrix diagonal` | A GPU pair that cannot talk. `N/A` on the diagonal is normal — off it is a dead path |
| `slowest GPU measured <n> TFLOPS` | One GPU below its siblings — the per-GPU spread is the finding |

### The two LLM jobs

| Reason | Implicates |
|--------|-----------|
| `no training step timings` | The run produced no training output at all — both LLM jobs. Staging or the container, not the node — check the image and `LLM_HF_HOME` before touching hardware. `VERDICT_DETAIL` gives the line count of the result file, which says whether the job got far enough to print anything |
| `fewer than <n> training step timings` | `llm-pretrain` started and stopped. The wall limit, a rank dying quietly, or a container exiting mid-run. The median it did produce is not evidence of health |
| `fewer than <n> GPUs reported step timings` | `llm-pretrain-solo`: a GPU produced nothing **while its siblings trained**. `VERDICT_DETAIL` names which ranks did report, so the missing one is the finding. None reporting is `no training step timings` above, not this |
| `a GPU reported fewer than <n> step timings` | All four started, one stopped early. Names the GPU and its count. A single-device fault, not a node-wide one |
| `per-GPU step times disagree -- spread above <n>` | The four copies ran to completion and one was slow. `VERDICT_DETAIL` names the GPU and its margin — the most specific per-device finding in the tree |
| `step time above <n> ms` | The whole tray is slow together, which the spread check passes by construction. Read it against the fleet median before assuming the node |

The first four are all "the run did not finish", and they are ordered by how
much of it did. Only the last two are performance findings; the rest are a run
that never got far enough to have a performance. See
[explanation/llmb.md#a-run-that-stopped-early](../explanation/llmb.md#a-run-that-stopped-early).

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
| `empty result file` / `no result file` | Nothing was written. Frequently ownership — see [layout.md#result-path-ownership](layout.md#result-path-ownership) |
| `job reported FAIL` | Preflight, most often: the step did not receive the whole node |

## Drain reasons

`sinfo -R` gives a reason; `report_health.sh` groups nodes by the *set* of checks
they failed, and `report_health.sh --diff <node>` diffs one node against the baseline for
each check it fails. One node per group is enough — the rest failed the same way.

Broad mapping from the 46 checks:

| Checks | Component |
|--------|-----------|
| `bios`, `os`, `kernel-params`, `numa`, `numa-settings` | Node configuration, not hardware. Usually a provisioning drift |
| `slurm-env` | A `SLURM_*`/`SBATCH_*`/`SRUN_*`/`SALLOC_*` variable exported on this node and not on the rest. The reason carries the three lines, so it names which of the agent environment, the login shell or `/etc/environment` differs — see [jobs.md#the-step-environment](jobs.md#the-step-environment) |
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
`report_health.sh --diff --all <node>`; they are often the fastest confirmation that a
node is cabled into the wrong rack. See
[health-checks.md#informational-checks](health-checks.md#informational-checks).

Not every drain is a health check. `slurm-recovery.sh` sorts drains into four
classes and **an operator drain is never cleared by anything in this tree** —
see [how-to/manage-drains.md](../how-to/manage-drains.md).

Two reasons this tree writes itself, rather than reads:

| Reason | Set by | Means |
|--------|--------|-------|
| contains `auto-retry` (`DRAIN_MARKER`) | `launch_job.sh` | Drained over a benchmark, and cleared by the sequencer once they pass |
| `unkillable job: N GPU process(es) survived …` | `slurm-recovery.sh`, under `RECOVER_DOWN_UNKILLABLE=yes` | State `DOWN`, not drained. A step outlived its own kill and the node needs a reboot — [how-to/clear-an-unkillable-step.md](../how-to/clear-an-unkillable-step.md) |

# Benchmark jobs (`jobs/`)

`jobs/` covers the single-node (SNT) rows of the
[AI Factory Testing Plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md).
Which subset runs depends on the delivery methodology for the site — see the
commented catalog above `benchmarks=` in `actions/launch_job.sh`.

| Plan row | Job | Variants |
|----------|-----|----------|
| DCGM Diagnostics `-r 2` / `-r 3` / `-r 4` | `dcgm-r2`, `dcgm`, `dcgm-r4` | TTM / Hybrid / Exhaustive |
| nvbandwidth | `nvbandwidth` | all |
| NCCL Single Node, NVLink | `allreduce`, `alltoall` | all |
| NCCL Single Node, No NVLink | `allreduce-nonvlink`, `alltoall-nonvlink` | all |
| NVSM Stress Test | `nvsm` | Hybrid, Exhaustive — **DGX only** |
| STREAM + Memtester | `stream`, `memtester` | Exhaustive |
| stress-ng | `stress-ng` | Exhaustive |
| stressapptest | `stressapptest` | Exhaustive |
| fio | `fio` | Exhaustive |
| ethr | `ethr` | Exhaustive |
| nvloom — Single-Node Health + Burn-In | `nvloom` | Exhaustive (optional) |
| MNUberGEMM Burn-In | `mnubergemm` | Hybrid, Exhaustive |
| Single-Node LLM Pre-Training | `llm-pretrain` | all |
| HPL / cuBlasMatMul (single-node GEMM) | `hpl`, `cublasmatmul` | remediation-only |

Three single-node plan rows have no `.sbatch` file because they are not Slurm
jobs: **Inventory & BOM Verification (ClusterMinder)** and **Network Fabric
Health Check (CVT)** are externally deployed collectors with their own MOPs, and
**Pre-Flight Checks** run through `actions/node_health.sh` and the Slurm prolog
rather than as a submitted job.

## Before enabling a job

The default `benchmarks=` list holds only jobs whose dependencies are always
available: `dcgm` uses a host binary, and the NCCL jobs use the
`hpc-benchmarks` image that `build_containers.sh` pulls from the public catalog.

Everything else needs one of three things first:

- **An image.** `nvbandwidth`, `nvloom`, and `mnubergemm` have no public
  upstream image — see [containers.md](containers.md) for how to build or
  obtain each one.
- **Site values.** Jobs outside the default list ship with placeholders —
  interface names, the `ethr` server host, the `fio` scratch directory, and the
  pass thresholds in `stream.sbatch` and `cublasmatmul.sbatch`. Set these per
  platform before adding the job to the list.
- **A supported platform.** `nvsm` is **DGX only** — it ships with DGX OS and
  only carries platform definition files for DGX platforms, so on anything else
  it fails on every node and drains the cluster for a tool that was never going
  to run. It is out of the default list for that reason. On a DGX site it also
  needs a sudoers grant on every compute node — see [nvsm.md](nvsm.md).

## Adding a new benchmark

1. Copy `jobs/example.sbatch` to `jobs/<name>.sbatch`.
2. Set `job_name=<name>` and optionally `totalRuns=N`.
3. Add your workload between the job and parse sections.
4. The parse section must `echo PENDING` if the workload ran and `echo FAIL` if
   it could not, as the last line — capture the exit status immediately after
   the workload with `rc=$?` and end the file with:

   ```bash
   [[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL
   ```
5. Add a gate for `<name>` to the `case` in `verdict.sh`. Without one it falls
   through to `_v_gate_generic`, which only checks for common crash signatures
   and cannot know what your job's output is supposed to look like.
6. Add a fixture under `tests/fixtures/` and a line to `tests/verdict-test.sh`.
7. Add `<name>` to the `benchmarks=` list in `actions/launch_job.sh`.

## Where a pass is decided

An sbatch does **not** decide whether its own result is good. It reports only
whether it ran (`PENDING`) or could not (`FAIL`). `DONE` is derived by
`verdict.sh`, which is read by `launch_job.sh`, `status-check.sh` and
`status-daily-report.sh` every time they look at a result — it is never written
to disk.

That split exists because the alternative failed in a way nothing could
recover from. When each sbatch judged itself and wrote `DONE`, that verdict was
frozen at run time: `launch_job.sh` skips any job whose result file says `DONE`,
so tightening a gate could never re-examine the results it was written for. The
`-nonvlink` jobs ran entirely over TCP at 1.17 GB/s on 25 nodes, all reporting
`DONE`; the fix written to catch exactly that was correct, deployed, and
structurally unable to reach a single one of them. Clearing them by hand was the
only way out.

With the verdict derived, tightening a gate re-judges every result already on
disk on the next sweep. Result files ending in the old `DONE` marker are treated
as legacy and re-judged rather than trusted, which is what retires them.

A gate should require positive evidence of a completed run, not just the absence
of the word `error`. Every job here greps for something the tool only prints
when it actually ran — a results table, a health summary, a bandwidth figure —
because an empty output file otherwise reports a pass.

Where the point of a job is *how* the work ran rather than that it ran, gate on
that too. `allreduce-nonvlink` and `alltoall-nonvlink` exist to exercise the
HCAs, and NCCL will silently fall back to TCP over `bond0` when it finds no
device — producing a correct, complete, entirely worthless result. Both jobs
force the transport (`NCCL_NET=IB`), and the gate rejects any run whose
per-channel `via NET/...` lines name Socket.

### Judge the channels, never the plugin registration

Only the per-channel lines are evidence of where data went:

```
Channel 01/1 : 2[2] -> 3[3] [receive] via NET/Socket/0/Shared    <- TCP
Channel 00/0 : 0[0] -> 1[1] via P2P/MNNVL                        <- NVLink
```

These are **not**, in either direction:

```
NET/IB : No device found.
NET/Socket : Using [0]bond0:10.40.19.36<0>
Using network Socket
Using network IB
```

They name the net plugin NCCL registered, which it does whether or not the net
is ever used. A perfectly healthy single-node NVLink run initialises a net
plugin for potential inter-node use, finds no IB, falls back to Socket for that
role, logs all of the above, and then moves every byte over NVLink at 220 GB/s.

Both halves of this have now been got wrong once. `Using network IB` was
accepted as proof a run reached the HCAs when it proves nothing of the sort, and
then `Using network Socket` was rejected as proof a run had fallen to TCP —
failing a healthy 220.837 GB/s allreduce with 32 channels of `via P2P/MNNVL` as
`collective carried over TCP`. Both fixtures are in `tests/fixtures/`.

The NVLink-scope jobs forbid `via NET/` outright — any channel on the network,
Socket or IB, means the collective left NVLink. That is stated as a forbid
rather than as "require `via P2P`" deliberately: a forbid cannot false-fail a
legitimate path that happens to be named something the one healthy log inspected
did not contain.

### Host HCAs are not container HCAs

`jobs/nccl-hca.sh` does two separate things, and conflating them is what cost
weeks. `nccl_hca_detect` runs on the **host** and chooses what to pin
`NCCL_IB_HCA` to. `NCCL_HCA_PROBE` runs **inside the container** and reports
what is visible there, via `ibv_devinfo` — the same libibverbs call NCCL makes.

Those answer different questions. enroot gives the container a fresh `/dev`, so
the host list can be complete and correct while the container sees nothing at
all. Checking by hand over ssh puts you on the host and will show a healthy HCA
list no matter how broken the container's view is. Both lists are now printed
into every result file:

```
INFO: host /sys/class/infiniband: mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_bond_0
INFO: forcing collectives over HCAs: mlx5_0,mlx5_1,mlx5_2,mlx5_3
INFO: container NCCL_IB_HCA: mlx5_0,mlx5_1,mlx5_2,mlx5_3
INFO: container /dev/infiniband: rdma_cm uverbs0 uverbs1 uverbs2 uverbs3
INFO: container sees HCAs (via ibv_devinfo): mlx5_0 mlx5_1 mlx5_2 mlx5_3
```

The last line is a fixed format because `verdict.sh` gates on it: `(none)`
fails as `no HCA visible inside the container`.

The `ib` checks are ordered by causation, not severity — the first to fire is
the one whose reason gets reported. The chain runs: fresh `/dev` → container
cannot see the HCAs → `NET/IB : No device found.` → IB plugin fails to load →
fallback to Socket → every channel over `bond0`. Checking the last of those
first would report the whole cluster as `collective carried over TCP`, which is
true, and would send someone to look at the fabric instead of at a missing bind
mount. Keep new checks in causal order.

Bandwidth floors live in `VERDICT_MIN_BW_NVLINK` and `VERDICT_MIN_BW_NONVLINK`
at the top of `verdict.sh`. They are set low deliberately — enough to catch a
transport that is obviously wrong, not to assert the fabric performs to spec.
Raise them once a known-good run on the platform establishes what good looks
like. They read the `# Avg bus bandwidth` summary line, which is an average
across every message size and roughly half the largest-size figure that
`status-daily-report.sh` reports as the metric; do not compare the two.

Run `tests/verdict-test.sh` after changing a gate. It checks `verdict.sh`
against captured result files, including a real socket run, and asserts the
reason as well as the verdict.

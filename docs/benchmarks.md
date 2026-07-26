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
per-channel `via NET/...` lines name Socket. Note that `Using network IB` alone
does not clear a run: it names the plugin NCCL registered, not what the bytes
crossed.

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

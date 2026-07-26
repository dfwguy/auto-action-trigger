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
| NVSM Stress Test | `nvsm` | Hybrid, Exhaustive |
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
available: `dcgm` and `nvsm` use host binaries, and the NCCL jobs use the
`hpc-benchmarks` image that `build_containers.sh` pulls from the public catalog.

Everything else needs one of two things first:

- **An image.** `nvbandwidth`, `nvloom`, and `mnubergemm` have no public
  upstream image — see [containers.md](containers.md) for how to build or
  obtain each one.
- **Site values.** Jobs outside the default list ship with placeholders —
  interface names, the `ethr` server host, the `fio` scratch directory, and the
  pass thresholds in `stream.sbatch` and `cublasmatmul.sbatch`. Set these per
  platform before adding the job to the list.

`nvsm` needs neither, but it does need a sudoers grant on every compute node —
see [nvsm.md](nvsm.md).

## Adding a new benchmark

1. Copy `jobs/example.sbatch` to `jobs/<name>.sbatch`.
2. Set `job_name=<name>` and optionally `totalRuns=N`.
3. Add your workload between the job and parse sections.
4. The parse section must `echo DONE` on success or `echo FAIL` on failure as
   the last line. Nothing else counts as a pass.
5. Add `<name>` to the `benchmarks=` list in `actions/launch_job.sh`.

The parse section should require positive evidence of a completed run, not just
the absence of the word `error`. Every job here greps for something the tool
only prints when it actually ran — a results table, a health summary, a
bandwidth figure — because an empty output file otherwise reports `DONE`.

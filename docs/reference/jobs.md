# Benchmark jobs (`jobs/$JOBS/`)

The job set is a directory: `jobs/nvl72/` ships, and `JOBS` in `SETTINGS`
selects which one `launch_job.sh` submits from. Everything below describes
`jobs/nvl72/`; a second platform is a second directory, not a second copy of
this framework.

`jobs/nvl72/` covers the single-node (SNT) rows of the
[AI Factory Testing Plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md).

## The job catalog

| Job | Description | Tier | Plan row |
|-----|-------------|------|----------|
| `dcgmi-r1` | Software and deployment checks (`dcgmi diag -r 1`) | all | DCGM Diagnostics |
| `dcgmi-r2` | TTM DCGM gate (`dcgmi diag -r 2`) | TTM | DCGM Diagnostics |
| `dcgmi-r3` | Hybrid DCGM gate (`dcgmi diag -r 3`) | Hybrid | DCGM Diagnostics |
| `dcgmi-r4` | Exhaustive gate (`dcgmi diag -r 4`) | Exhaustive | DCGM Diagnostics |
| `nvbandwidth` | HBM / PCIe / NVLink bandwidth | Hybrid / Exhaustive | nvbandwidth |
| `allreduce` `alltoall` | NCCL single-node, NVLink scope | Hybrid / Exhaustive | NCCL Single Node, NVLink |
| `allreduce-forcesharp` | NCCL all-reduce, NVLink scope, NVLS/SHARP required | Hybrid / Exhaustive | NCCL, SHARP required |
| `allreduce-nonvlink` `alltoall-nonvlink` | NCCL single-node, no NVLink (HCA loopback) | Hybrid / Exhaustive | NCCL Single Node, No NVLink |
| `nvsm` | NVSM stress — **DGX only** | Hybrid / Exhaustive | NVSM Stress Test |
| `stream` `memtester` | CPU memory bandwidth + DRAM integrity | Exhaustive | STREAM + Memtester |
| `stress-ng` | CPU stress | Exhaustive | stress-ng |
| `stressapptest` | Extended memory integrity | Exhaustive | stressapptest |
| `fio` | Local NVMe / shared storage | Exhaustive | fio |
| `ethr` | North-south management + storage NIC | Exhaustive | ethr |
| `nvloom` | MNNVL fabric — optional / exploratory | Exhaustive | nvloom |
| `mnubergemm` | Burn-in | Hybrid / Exhaustive | MNUberGEMM Burn-In |
| `llm-pretrain` | Single-node LLM pre-training gate — host-launched | Hybrid / Exhaustive | Single-Node LLM Pre-Training |
| `llm-pretrain-solo` | 4 independent 1-GPU pre-training copies; finds *which* GPU is slow | Hybrid / Exhaustive | — |
| `hpl` `cublasmatmul` | Remediation-only single-node GEMM — run by hand | Remediation | HPL / cuBlasMatMul |

Three single-node plan rows have no `.sbatch` file because they are not Slurm
jobs: **Inventory & BOM Verification (ClusterMinder)** and **Network Fabric
Health Check (CVT)** are externally deployed collectors with their own MOPs, and
**Pre-Flight Checks** run through `actions/node_health.sh` and the Slurm prolog
rather than as a submitted job.

## What each job exercises

The plan row names the gate; it does not say what the tool measures. Each job in
one line, because "which of these would have caught this" is the question asked
when a node misbehaves and nothing drained it:

| Job | What it measures |
|-----|------------------|
| `dcgmi-r1` … `dcgmi-r4` | DCGM diagnostics at rising depth — `-r 1` is software-only, `-r 2` the fast TTM gate, `-r 3` the Hybrid gate, `-r 4` extended stress. See [the dcgmi gates](#the-dcgmi-gates) |
| `nvbandwidth` | per-GPU HBM, PCIe and NVLink/NVSwitch bandwidth. Surfaces PCIe width/speed negotiation faults — x8 where x16 was ordered — and HBM channel failures that DCGM does not report as an explicit bandwidth figure |
| `allreduce`, `alltoall` | NCCL collectives over NVLink, single node: does the collective work, and at what bus bandwidth |
| `allreduce-forcesharp` | the same collective with the NVSwitch's in-network reduction made mandatory — does the switch offload run at all |
| `allreduce-nonvlink`, `alltoall-nonvlink` | the same collectives forced over the compute-plane HCAs with NVLink excluded (GB300 MOP 7.3 Scope A, loopback east-west). Confirms the in-system network is configured and performant |
| `nvsm` | system-level compute, memory and thermal stress across every GPU on the node, plus a health summary. Pre-burn-in gate — quarantine a failing node before it spends three days in `mnubergemm` |
| `stream` | sustained CPU memory bandwidth (Copy/Scale/Add/Triad) against arrays too large to fit in cache. Validates DRAM channels and NUMA layout before any GPU workload |
| `memtester` | DRAM integrity and ECC behaviour. The integrity half of the pair `stream` covers the bandwidth half of |
| `stress-ng` | CPU stress across arithmetic, SIMD, cache, mmap and OS primitives. Exposes thermal instability, power-delivery limits and CPU-side faults before GPU burn-in |
| `stressapptest` | randomized memory access across all DRAM with simultaneous I/O and network pressure. Surfaces marginal cells, uncorrectable ECC and signal-integrity faults that lighter memory tests miss |
| `fio` | local NVMe and shared storage (VAST / Lustre / WekaFS) throughput, IOPS and latency at several block sizes and queue depths, before workloads commit data to it |
| `ethr` | north-south throughput and latency on the in-band management and storage NICs (ConnectX / BlueField). Deliberately not the same traffic as NCCL or perftest, which are east-west RDMA — these paths are otherwise never exercised |
| `nvloom` | MNNVL fabric validation per node: bandwidth uniformity across CE and SM engines, outlier detection, thermal behaviour under sustained collective load. Incubation tool, not a required gate in any variant |
| `mnubergemm` | GPU burn-in — sustained mixed GEMM load for hours, the 24–72 hour row of the plan |
| `llm-pretrain` | end-to-end Llama 3.1 8B pre-training scoped to one tray, 4-way data parallel. The only job that exercises the whole stack together: framework, container, data pipeline, checkpointing and intra-node collectives |
| `llm-pretrain-solo` | the same recipe at scale 1, run as four independent single-GPU copies. No collectives at all: every GPU does identical work, so an outlier step time names a slow device rather than a slow node |
| `hpl`, `cublasmatmul` | single-node GEMM, for isolating one suspect node during remediation. GB300/B300 uses `cublasmatmul` (GB300 MOP 7.5.2); GB200 uses `hpl` |

## The dcgmi gates

`dcgmi-r1`, `dcgmi-r2`, `dcgmi-r3` and `dcgmi-r4` are one job written four
times. The files are byte-identical apart from the `-r` level, the `job_name`
and `-o` path that follow from it, and the two time limits that level needs —
`#SBATCH -t` and `JOB_TIMEOUT`. There is no `dcgm` job without a level: the
level is the whole difference between them, so it belongs in the name rather
than in whichever file happened to be first.

| Job | `dcgmi diag` | What it adds | Tier |
|-----|--------------|--------------|------|
| `dcgmi-r1` | `-r 1` | software and deployment checks — driver, NVML, permissions, persistence mode. No stress at all, so it says "this node can be tested" before a sweep spends hours finding out it cannot | quick gate |
| `dcgmi-r2` | `-r 2` | adds the short hardware probes: PCIe/NVLink, memory bandwidth, SM stress at low duration | TTM |
| `dcgmi-r3` | `-r 3` | adds the full stress plugins — targeted stress, targeted power, memory bandwidth at length | Hybrid |
| `dcgmi-r4` | `-r 4` | the same plugins run long, for faults that only appear under sustained thermal and power load | Exhaustive |

The default `BENCHMARKS` runs `dcgmi-r1` and `dcgmi-r3`: `-r 1` is nearly free
and catches a misconfigured node before anything else is attempted, and `-r 3`
is the deepest level that still fits inside a normal sweep. `-r 2` is there for
a TTM schedule that cannot afford `-r 3`, and `-r 4` for a node under
investigation.

All four share one gate in `verdict.sh` — the output format does not change with
the level, only how much of it there is. `tests/verdict-test.sh` checks that
every level reaches that gate, because a level missing from the `case` arm would
fall through to the default and pass everything.

## Notes on individual jobs

Things about one job that are not true of the rest, and that a reader of the
generic header would get wrong.

- **`nvloom` must not be given `--gpus-per-task`.** It assigns GPUs by MPI local
  rank, so scoping CUDA devices per task leaves a rank with no device it is
  allowed to use and the run dies in `CUDA_ERROR_NO_DEVICE` (MOP section 2.4).
  The allocation asks with `--gres` for that reason, and exports
  `NVIDIA_VISIBLE_DEVICES=all` so the Pyxis/Enroot hook bind-mounts every GPU.
- **The `dcgmi-r*` jobs run `dcgmi` in the batch body, not in a step.** That is
  deliberate — it sees the job's GPUs without restating `--gres` — and it is why
  they bound their work with `timeout` rather than `srun --time`. The `--gres`
  line is still load-bearing: without it Slurm reads the job as GPU-free, and
  anything co-scheduled dies allocating framebuffer that `dcgmi`'s memory and
  stress plugins have already taken.
- **`timeout` sends TERM first and KILL 60 s later.** TERM so `dcgmi` can tear
  down its connection to the host engine and leave nothing wedged behind it;
  KILL for one that will not go. `timeout` reports 124 when the command took the
  TERM and exited, and 137 when the KILL had to fire — and ignoring a TERM is
  exactly what a wedged diagnostic does, so both count as an overrun.
- **`llm-pretrain` is not an `.sbatch`.** `llmb-run` submits its own Slurm job,
  so the job is a host launcher — `llm-pretrain.sh`, run on the node rather than
  submitted. Its `--scale 4` matches the nvl72 node's four GPUs; on another
  platform both move together. Enabling it is
  [how-to/enable-llm-pretrain.md](../how-to/enable-llm-pretrain.md).
- **Both LLM jobs run below the recipe's characterised scale, with `--force`.**
  The numbers are good for comparing nodes to each other, and are **not**
  comparable to NVIDIA's published 8-GPU figures. See
  [explanation/llmb.md#running-below-the-characterised-scale](../explanation/llmb.md#running-below-the-characterised-scale).
- **`llm-pretrain-solo` ships with its training command unfilled** and refuses
  to run until it is set. See
  [how-to/enable-llm-pretrain.md#3-filling-in-the-solo-training-command](../how-to/enable-llm-pretrain.md#3-filling-in-the-solo-training-command).
- **`nvsm` is not a container job.** It is installed on the host alongside
  `dcgmi`, refuses to run as anyone but root, and a batch task has no tty for a
  password prompt — so it needs a NOPASSWD sudoers grant on every compute node
  and fails fast and loudly if it cannot get to root, rather than reporting a
  bogus hardware failure. See
  [how-to/enable-nvsm.md](../how-to/enable-nvsm.md).
- **`ethr` needs a server started by hand**, once, outside the job: `ethr -s` on
  the headnode or a storage-network endpoint. It is a single static Go binary —
  install it on the host from `github.com/microsoft/ethr` rather than
  containerizing it. An interface in `IFACES` that this node does not have is
  skipped rather than failed, and the skip is reported in a fixed wording the
  gate reads: nothing ran, so there is no exit status to report.
- **`stream` runs out of the `hpc-benchmarks` image**, the same one the NCCL
  jobs use, and its `stream-cpu-test.sh` is Arm SBSA only. On an x86 host,
  install STREAM there or build it into a site image.
- **`nvbandwidth`'s image is architecture-specific, and that is a CPU split**
  rather than a GPU-generation one — Grace and Vera are ARM, Intel and AMD hosts
  take the x86 build. The job runs the full default suite of 33 tests, which
  includes every test the plan calls out by name; `nvbandwidth -l` and
  `-t <test>` are for triage.
- **`--mem=0` is load-bearing rather than tidy in `memtester` and
  `stressapptest`.** Both size their footprint at 80% of the node's
  `MemAvailable`, so without it the step is capped at the partition's default
  memory and is killed partway through — which reads as a DRAM failure rather
  than as a scheduling mistake.
- **Multi-pass jobs report one status for all their passes.** `fio` (four
  passes), `ethr` (two per interface) and `nvsm` (stress, then health) set an
  aggregate that is only ever raised, so a later success cannot overwrite an
  earlier failure: any pass failing means the job did not run to completion.

## The allocation header

Every job in `jobs/nvl72/` asks for the whole node. That is what makes a
bandwidth or latency number mean anything: a benchmark sharing a node with
another job is measuring the other job.

The one principle behind the header shape:

> **`--exclusive` is a job-level guarantee. Steps inherit only what you
> *explicitly requested*, never what you were implicitly granted.**

| Asked for | Job gets | Step (`srun`) gets |
|---|---|---|
| `--exclusive` alone | all CPUs, all GPUs, default memory | all CPUs, **no GPUs** |
| `--exclusive --gres=gpu:4` | all CPUs, 4 GPUs, default memory | all CPUs, 4 GPUs |
| `--exclusive --mem=0` | all CPUs, all GPUs, all memory | — |
| `--exclusive -c 32` | all CPUs | `--exact` implied → **32 cores** |

So every job states:

```bash
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0                 # never implied — say it
#SBATCH --gres=gpu:4            # GPU jobs only — do not rely on --exclusive
#SBATCH --ntasks-per-node=4     # one task per GPU, or 1 for single-task jobs
#SBATCH -t <walltime>
#SBATCH --nice=<tier>           # queue priority — see below
```

and no job sets `--cpus-per-task`. It is load-bearing and dangerous: setting it
implies `--exact`, and the step silently drops to that core count inside an
allocation holding every core. A job that needs it must re-state it on the
`srun` or export `SRUN_CPUS_PER_TASK="${SLURM_CPUS_PER_TASK}"`, and keep
`ntasks-per-node × cpus-per-task` equal to the node's core count or cores sit
stranded.

The GPU count is a literal `4` in both the `--gres` line and the preflight
below. On a platform with a different count, change both together.

## Queue priority

Every job states its own `#SBATCH --nice`. Slurm subtracts it from the job's
priority, so **higher is later** and `0` is the front of the queue. Four tiers:

| `--nice` | Jobs | Why |
|---|---|---|
| `0` | nothing in this tree | left free for a job queued by hand, which is what `sbatch` defaults to |
| `1`-`4` | the `dcgmi-r*` gates, one per `-r` level | fast, and they decide whether the rest of the sweep is worth running at all |
| `20` | every other benchmark | the sweep's own tier |
| `100000` | `mnubergemm` | burn-in, always last |

The gates start at `1` rather than `0` so that anything queued by hand goes in
front of them: a bare `sbatch` with no `--nice` lands at `0`, and `0` is now
left empty for exactly that. Each gate then takes its own `-r` level as its nice
value — `dcgmi-r1` at `1` through `dcgmi-r4` at `4` — so the levels run in
ascending order and the cheap gate is not left waiting behind the long one.

It lives in the job file, not in `SETTINGS` and not in `launch_job.sh`, for the
same reason `-t` and `--exclusive` do — it is part of how this job wants to be
scheduled, and stating it here means a job submitted **by hand** carries the
same priority as one the sequencer submits. `hpl` and `cublasmatmul` are
remediation jobs run by hand, and they still queue at `20` behind a dcgmi gate.
So the empty `0` tier only helps a job submitted *without* a `--nice`; to push a
job file from this tree to the front, override it on the command line:
`sbatch --nice=0 hpl.sbatch`.

Two limits worth knowing:

- **Nice does not preempt.** Every job is `--exclusive`, so whatever is already
  running keeps the node until it finishes. Priority only reorders what has not
  started. Interrupting a running burn-in needs Slurm preemption
  (`PreemptType`/`PreemptMode`, with the lists in different partitions or
  QOSes), which is scheduler configuration.
- **`100000` is deliberately large.** Under `priority/basic`, priority is
  derived from the job id, so a nice value only outranks jobs submitted within
  that many ids. A small number would work on a quiet cluster and silently stop
  working on a busy one.

Since the sequencer keeps only one job of ours out at a time, `--nice` no longer
orders our own jobs against each other and now matters only against work
submitted by hand or by other users — see
[explanation/sequencing.md#cadence-is-per-job-not-per-node](../explanation/sequencing.md#cadence-is-per-job-not-per-node).

## Two time limits, and the order they fire in

Every job bounds its work twice, and `#SBATCH -t` is deliberately the larger:

| | Bounds | Set to |
|---|---|---|
| `srun --time="$STEP_TIMELIMIT"` | the step | 2× the [testing plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md) estimate for that row, floored at 15 min |
| `#SBATCH -t` | the job | the step limit(s) + ~10 min |

The margin exists so the step limit is what fires, because the two kills do not
leave the same result file behind:

- **The job walltime** kills the batch script itself. Nothing runs after it, so
  no marker is written, and `verdict.sh` reads a result file with no end marker
  as `INCOMPLETE` — "the job died before finishing", indistinguishable from a
  node that crashed. The node is retried next sweep, overruns again, and never
  converges.
- **The step time limit** cancels the step and logs
  `*** STEP <id> ON <node> CANCELLED AT <time> DUE TO TIME LIMIT ***` into the
  result file. The batch script survives, `srun` returns non-zero, and the parse
  block writes `FAIL`. `VERDICT_RUN_ERRORS` already matches that line, so every
  gate reports an overrun the same way, with the reason Slurm wrote.

An overrun is usually a real finding — a node running its work several times
slower than its peers — and belongs in the log as one rather than as a node that
mysteriously stopped.

Where the estimate is small the floor binds instead of the doubling: container
start and a multi-gigabyte image read over NFS do not scale with a two-minute
test, and doubling `~2 min` to four would cancel healthy `dcgmi-r2` steps.
Where a job configures its own run duration — `stressapptest`'s `RUN_SECONDS`,
`mnubergemm`'s `--time_to_run` — that is the estimate to double, not the plan's
figure for the row. Where a job runs several steps (`fio` and `ethr` per pass,
`nvsm`'s stress and health steps), each carries its own limit and they have to
**sum** to less than the walltime — `ethr` in particular sizes its walltime for
one interface, so adding a second to `IFACES` means raising `#SBATCH -t` too.

The four `dcgmi-r*` jobs bound their work with `timeout` instead of
`srun --time`. `dcgmi diag` runs in the batch script body rather than in a step,
so there is no step for `--time` to bound. `JOB_TIMEOUT` there is a `timeout(1)`
duration (`40m`, not `0:40:00`), and the job writes `timeout: killed after <n>`
on 124 *or* 137, which `VERDICT_RUN_ERRORS` matches the same way it matches
Slurm's `CANCELLED AT`. Both mechanisms buy the same property — the batch script
survives to write a marker — but prefer `--time` wherever there is a step: it is
Slurm's own accounting, and does not depend on a signal reaching the right
process.

### What each job's limits were derived from

The arithmetic used to sit in the job it applied to, where nobody could compare
two of them. It is stated once, here, so that a limit raised for one job can be
checked against how its neighbours were sized:

| Job | Step limit | `#SBATCH -t` | Derivation |
|---|---|---|---|
| `allreduce`, `allreduce-forcesharp`, `alltoall`, and the `-nonvlink` pair | `0:15:00` | `0:25:00` | 2× the plan's < 5 min for single-node NCCL — the 15 min floor is what binds |
| `dcgmi-r1` | `15m` (`timeout`) | `0:25:00` | 2× under a minute of software checks — the 15 min floor is what binds |
| `dcgmi-r2` | `15m` (`timeout`) | `0:25:00` | 2× ~2 min, floored at 15 min |
| `dcgmi-r3` | `40m` (`timeout`) | `0:50:00` | 2× ~20 min for `dcgmi -r 3` |
| `dcgmi-r4` | `3h` (`timeout`) | `3:10:00` | 2× ~45–90 min, taking the upper end |
| `nvbandwidth` | `0:30:00` | `0:40:00` | 2× ~15 min |
| `nvloom` | `1:00:00` | `1:10:00` | 2× the plan's 30 min for the Scope 1 health check |
| `nvsm` | `0:35:00` stress + `0:05:00` health | `0:50:00` | 2× ~20 min, which `STRESS_SECONDS=1200` matches; the two steps sum inside the walltime |
| `stream`, `memtester` | `4:00:00` | `4:10:00` | 2× the ~1–2 hr STREAM + Memtester row, upper end |
| `stress-ng` | `2:00:00` | `2:10:00` | 2× `TIMEOUT=3600`, which is the plan's ~1 hr |
| `stressapptest` | `4:00:00` | `4:10:00` | 2× `RUN_SECONDS=7200`; the plan's row is 2–4 hr |
| `fio` | `0:30:00` per pass | `2:10:00` | 2× the plan's ~1 hr, divided over four passes (`read`, `write`, `randread`, `randwrite`) |
| `ethr` | `0:30:00` per pass | `1:10:00` | 2× the plan's ~30 min; two passes per interface, and the walltime holds **one** interface |
| `llm-pretrain` | `2:00:00` | `2:10:00` | 2× the plan's ~30–60 min, upper end |
| `hpl` | `1:50:00` | `2:00:00` | the plan gives no estimate for the remediation GEMM, so this is a bound rather than a doubling |
| `cublasmatmul` | `0:20:00` | `0:30:00` | 2× its own `DURATION=600`, for the same reason |
| `mnubergemm` | `6:30:00` | `6:41:00` | `--time_to_run 21420` (5:57) **plus half an hour**, not 2× — see below |

`mnubergemm` is the one job that does not double, and the reason generalises to
any workload that caps its own runtime for hours. A step limit at twice a
six-hour run cannot catch a hung one: it waits six hours past the point the job
should have finished before admitting anything is wrong, and `MAX_JOB_HOURS`
then has to be set high enough to clear the padding rather than the work. Its
four limits are a ladder that moves together — the workload's own
`--time_to_run`, then `STEP_TIMELIMIT`, then `#SBATCH -t`, then `MAX_JOB_HOURS`
in `SETTINGS`, which is the rung that is not in the job file. See
[settings.md#retry-and-drain-policy](settings.md#retry-and-drain-policy).

Where a job configures its own duration the padding is the point: an `ethr` pass
is 30 s of traffic inside a 30 min limit, and a `fio` pass is 120 s of I/O plus
laying out the test file. In both cases the limit is covering the failure the
workload does not bound — an `ethr` that cannot reach its server and sits in
connection retries, a `fio` laying out files on a cold filesystem — not the
measurement.

## Preflight

Every job opens with a one-line `srun` that reports what the *step* holds:

```
preflight: <node> gpus=4 cores=144/144
```

and fails the job if it is not what was asked for. This is checked from inside a
step because that is the only place that can see it — a step is a different
cgroup from the batch script body, so a correct `AllocTRES` on the job tells you
nothing about what the workload will get. `jobs/nvl72/example.sbatch` carries
the full reasoning, including why the passing line is worded the way it is:
several parse blocks and `verdict.sh` grep the same file case-insensitively for
`fail`/`warn`/`error`, and the nccl-tests parser reads any line starting with a
digit as a data row.

Two things to check by hand when a job looks wrong:

| Check | Command | Expect |
|---|---|---|
| Job holds everything | `scontrol show job $ID \| grep -i alloctres` | `cpu=<all>,gres/gpu=4,mem=<all>` |
| Step holds it too | `sacct -j $ID -o JobID,AllocTRES%60` | the `.0` row matches its parent |
| Only one job on the node | `squeue -w <node> -t R` | one row |

Three partition-level settings make the header redundant, and are worth asking a
Slurm admin for: `LaunchParameters=srun_exclusive_allocation` (steps inherit the
whole allocation), `DefMemPerNode=0` (removes the `--mem=0` requirement), and
`OverSubscribe=EXCLUSIVE` (jobs get whole nodes without asking). The header is
written not to depend on any of them.

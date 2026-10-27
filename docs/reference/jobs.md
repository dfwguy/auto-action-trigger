# Benchmark jobs (`jobs/$JOBS/`)

The job set is a directory: `jobs/nvl72/` ships, and `JOBS` in `SETTINGS`
selects which one `launch_job.sh` submits from. Everything below describes
`jobs/nvl72/`; a second platform is a second directory, not a second copy of
this framework.

`jobs/h200x2/` is the starter profile for nodes with two H200 GPUs. It
ships only `dcgmi-r1`, requests `gpu:h200:2`, needs no container, and pairs with
`PARSERS=nvl72`. The job uses `dcgmi` from `PATH` or loads the `cuda-dcgm`
module. Add jobs only after validating their allocation, dependencies, and
verdict thresholds on that hardware.

`jobs/nvl72/` covers the single-node (SNT) rows of the
[AI Factory Testing Plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md).

`jobs/b300-spx/` is the same catalog, ported to GB300 nodes on a Spectrum-X
(RoCEv2) fabric rather than InfiniBand: 8 GPUs instead of 4, and the
`-nonvlink` pair loads the SPCX NCCL plugin instead of IB's. `jobs/nvl72-spx/`
is the same fabric port applied to `nvl72/`'s own node shape (4 GPUs)
unchanged — every job carries over from `nvl72/` except the `-nonvlink` pair
and the HCA-discovery library, which both spectrum-x directories share the
same filtering logic for. A site running either sets `PARSERS=spectrum-x`
alongside `JOBS=b300-spx` or `JOBS=nvl72-spx` — the two settings are
independent and neither implies the other — see
[settings.md#which-set-of-things-to-run](settings.md#which-set-of-things-to-run)
and
[explanation/judging-benchmarks.md#the-plugin-name-is-a-property-of-the-fabric](../explanation/judging-benchmarks.md#the-plugin-name-is-a-property-of-the-fabric).

`jobs/b300/` is `b300-spx/`'s 8-GPU node shape with `nvl72/`'s InfiniBand
fabric instead of Spectrum-X — the DCGM gates, both NCCL scopes,
`allreduce-forcesharp` and `mnubergemm` are covered. Neither `b300-spx/` nor
`nvl72-spx/` ships `allreduce-forcesharp`. `jobs/b300/` pairs with
`PARSERS=nvl72`, unchanged, since the transport is real IB.

## The pytorch NCCL jobs

`<job>-pytorch` is `<job>` with `nvidia+pytorch+<PYTORCH_TAG>-<arch>.sqsh` as the
image, for a newer NCCL than `hpc-benchmarks` carries. They sit beside the
originals; nothing is replaced. In `nvl72/` and `b300/` the env is the twin's,
unchanged (`NCCL_NET=IB`, no plugin); in the `-spx` directories it is the SPCX
set below. Each is judged by its twin's gate and floor, so
`VERDICT_MIN_PEAK_BW_*` applies unchanged. Build the image with
[`build_containers.sh pytorch`](../how-to/build-containers.md#pytorch).

What differs from the twin, besides the image:

| Change | Applies to | Why |
|---|---|---|
| `PMIX_MCA_*` and `OMPI_MCA_*` (ob1, tcp over bond0, UCC and HCOLL off), **commented out** | all four | the capture in issue #21 carried them; they stay off until a run shows the image needs them, and are deleted if it does not |
| one `env_pairs` array feeds both `export` and `--container-env` | all four | the image sets its own values, so an exported name not listed in `--container-env` is overridden |
| `NCCL_NET_PLUGIN=spcx`, no `NCCL_PLUGIN_PATH` or `LD_LIBRARY_PATH` | `-nonvlink`, `-spx` only | the plugin is found by name here rather than under `/opt/hpcx` |
| `NCCL_PXN_DISABLE`, `NCCL_IB_QPS_PER_CONNECTION=2`, `NCCL_NCHANNELS_PER_NET_PEER=1`, `NCCL_MAX_P2P_NCHANNELS=16`, `NCCL_GDRCOPY_ENABLE=1` | `-nonvlink`, `-spx` only | tuning carried from the capture in issue #21; not yet validated against the twin |

`NCCL_DEBUG=INFO` stays: the gates read `via NET/` and `Using network SPCX`,
which `WARN` does not print. The tuning row and the plugin row are the ones to
re-check on a node.

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
| `allreduce-pytorch` `alltoall-pytorch` `allreduce-nonvlink-pytorch` `alltoall-nonvlink-pytorch` | The four NCCL jobs above, run in the `pytorch` image, in all four platform directories. See [The pytorch NCCL jobs](#the-pytorch-nccl-jobs) | Hybrid / Exhaustive | same as the twin |
| `nvsm` | NVSM stress — **DGX only** | Hybrid / Exhaustive | NVSM Stress Test |
| `stream` `memtester` | CPU memory bandwidth + DRAM integrity | Exhaustive | STREAM + Memtester |
| `stress-ng` | CPU stress | Exhaustive | stress-ng |
| `stressapptest` | Extended memory integrity | Exhaustive | stressapptest |
| `fio` | Local NVMe / shared storage | Exhaustive | fio |
| `ethr` | North-south management + storage NIC | Exhaustive | ethr |
| `nvloom` | MNNVL fabric — optional / exploratory | Exhaustive | nvloom |
| `mnubergemm` | Burn-in — steady load | Hybrid / Exhaustive | MNUberGEMM Burn-In |
| `mnubergemm-pulse` | Burn-in — pulsed load, off by default | Hybrid / Exhaustive | MNUberGEMM Burn-In |
| `llm-pretrain` | Single-node LLM pre-training gate — frozen from an `llmb-run` capture | Hybrid / Exhaustive | Single-Node LLM Pre-Training |
| `deepseek-v3-proxy` | Reduced DeepSeek-V3 FP8-MX training on one four-GPU GB300 node; manual opt-in | Exploratory | — |
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
| `mnubergemm-pulse` | the same workload on a 720-second square wave — six minutes of load, six idle, synchronised across the allocation. Finds what a flat soak cannot: power-delivery response to a load step, and cooling response to the swing back. See [explanation/burn-in-waveform.md](../explanation/burn-in-waveform.md) |
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

The default `BENCHMARKS` runs `dcgmi-r1`, `dcgmi-r3`, and `dcgmi-r4`: `-r 1` is
nearly free and catches a misconfigured node before anything else is attempted,
`-r 3` is the deep normal-sweep gate, and `-r 4` adds sustained thermal and
power stress. `-r 2` remains available for a TTM schedule that cannot afford
`-r 3`.

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
- **`llm-pretrain` is a frozen capture.** Its allocation, container, mounts,
  environment and training command were taken from a real `llmb-run` submission
  and checked in; nothing on the node calls `llmb-run`. Its four ranks match the
  nvl72 node's four GPUs; on another platform both move together. Re-deriving it
  is [how-to/capture-an-sbatch-from-llmb-run.md](../how-to/capture-an-sbatch-from-llmb-run.md),
  and why it is frozen is
  [explanation/llmb.md#the-frozen-recipe](../explanation/llmb.md#the-frozen-recipe).
- **Both LLM jobs run below the recipe's characterised scale, with `--force`.**
  The numbers are good for comparing nodes to each other, and are **not**
  comparable to NVIDIA's published 8-GPU figures. See
  [explanation/llmb.md#running-below-the-characterised-scale](../explanation/llmb.md#running-below-the-characterised-scale).
- **`llm-pretrain-solo` is the same frozen recipe at `--num_gpus 1`**, run as
  four independent copies under one `srun --label`. Its training command was
  captured the same way as its sibling's; only the GPU count and the batch size
  differ.
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

## The step environment

Not setting `--cpus-per-task` is necessary but not sufficient, because the job
does not have to be the one that set it. Every job file therefore opens its body
with:

```bash
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK
```

Slurm carries cpus-per-task in two variables — the legacy `SLURM_CPUS_PER_TASK`
and, since 23.11, `SLURM_TRES_PER_TASK=cpu=N`. When both are present in a step's
environment and **disagree**, `srun` does not choose between them and does not
warn; it exits `fatal` before the step starts:

```
srun: fatal: cpus-per-task set by two different environment variables
             SLURM_CPUS_PER_TASK=1 != SLURM_TRES_PER_TASK=cpu=4
```

Either can arrive without the job asking. `launch_job.sh` submits with
`--export=ALL`, so anything in the agent's environment is inherited; a site
default such as `DefCpuPerGPU`, a partition or QOS `TRESPerTask`, or an
`SBATCH_CPUS_PER_TASK` in the submitting shell sets the other side; and a node
whose `srun` is a different major version from the controller that built the
environment can disagree about which is authoritative. The job file cannot tell
these apart and does not need to — it wants neither variable, which is the same
thing "no `--cpus-per-task`" was always trying to say.

The `unset` protects the job; it does not find the node that is exporting one.
That is the `slurm-env` health check, which reports the `SLURM_*`, `SBATCH_*`,
`SRUN_*` and `SALLOC_*` variables set in three places — the agent's own
environment, a clean login shell, and `/etc/environment` — and diffs them
against the baseline like any other check, so the node that differs from the
fleet is the node named in the drain reason. It reports the three apart because
the fix is a different file in each case: the agent's is whatever
`systemd --user` was started with, the login shell's is `/etc/profile.d/` or a
dotfile, and `/etc/environment` is read by PAM and by no shell at all. `agent:`
reads `not judged` when the check itself is running inside an allocation, where
Slurm sets all of these legitimately. A site that exports `SLURM_CONF` from
`/etc/profile.d/` will see it listed on every node; that is uniform, so it
matches the baseline and drains nothing. See
[reference/health-checks.md](health-checks.md).

The failure is worth recognising by sight because it does not look like itself.
`srun` never runs, so the preflight `||` branch fires and the result file reads
`preflight: the step did not receive the whole node` with **no** `preflight:
<host> gpus=…` line above it — and `verdict.sh` gates dcgmi on a Pass row, so
the report says `no dcgmi Pass row`, the same reason it gives for a node with no
GPUs. A missing counts line, or the `fatal:` string in the result file, tells
the two apart. See
[explanation/judging-benchmarks.md](../explanation/judging-benchmarks.md).

## Queue priority

Every job states its own `#SBATCH --nice`. Slurm subtracts it from the job's
priority, so **higher is later** and `0` is the front of the queue. Four tiers:

| `--nice` | Jobs | Why |
|---|---|---|
| `0` | nothing in this tree | left free for a job queued by hand, which is what `sbatch` defaults to |
| `1`-`4` | the `dcgmi-r*` gates, one per `-r` level | fast, and they decide whether the rest of the sweep is worth running at all |
| `20` | every other benchmark | the sweep's own tier |
| `100000` | `mnubergemm`, `mnubergemm-pulse` | burn-in, always last |

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
job file from this tree to the front, override it with `sbatch --nice=0` — along
with the `--export`, `--output` and `-w` such a submission also needs, which are
in
[how-to/submit-a-job-file-directly.md](../how-to/submit-a-job-file-directly.md).

Three limits worth knowing:

- **Nice does not preempt.** Every job is `--exclusive`, so whatever is already
  running keeps the node until it finishes. Priority only reorders what has not
  started. Interrupting a running burn-in needs Slurm preemption
  (`PreemptType`/`PreemptMode`, with the lists in different partitions or
  QOSes), which is scheduler configuration.
- **Nice does not stop a job being backfilled.** A low `--nice` is what makes a
  job *eligible* to start early in a gap ahead of higher-priority work, so
  `mnubergemm` at `100000` is last in every queue and still starts inside gaps
  all day. That is Slurm working, not the tier being ignored — see
  [explanation/sequencing.md#the-sweep-is-shaped-like-a-backfill-job-and-that-is-load-bearing](../explanation/sequencing.md#the-sweep-is-shaped-like-a-backfill-job-and-that-is-load-bearing).
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
| `llm-pretrain` | `0:20:00` | `0:30:00` | ~4× a captured 50-step run's 4:30, because the first run on a node also pays the image copy and model init |
| `llm-pretrain-solo` | `0:20:00` | `0:30:00` | the same, from a captured scale-1 run's 3:14; four copies share the node's cores, so the margin is not halved |
| `hpl` | `1:50:00` | `2:00:00` | the plan gives no estimate for the remediation GEMM, so this is a bound rather than a doubling |
| `cublasmatmul` | `0:20:00` | `0:30:00` | 2× its own `DURATION=600`, for the same reason |
| `mnubergemm` | `6:30:00` | `6:41:00` | `--time_to_run 21420` (5:57) **plus half an hour**, not 2× — see below |
| `mnubergemm-pulse` | `6:30:00` | `6:41:00` | the same ladder: the waveform changes what the run does, not how long it takes |

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

## DeepSeek-V3 proxy

`jobs/nvl72/deepseek-v3-proxy.sbatch` and the identical `nvl72-spx` job
follow Exemplar v26.06.01's
four-GPU GB300 proxy: NeMo 26.04.01, FP8-MX, 24 layers, hidden size 1024,
TP=1, PP=1, VP disabled, EP=4 and micro-batch size 4. It is a reduced
training workload, not full-model inference or a distributed fabric test.
The runner is inside the container; the only shared runtime input is the
cache named by `LLM_HF_HOME`. Experiment files stay in the writable container.

The parser requires 50 timing records and no recognized runtime errors. Its
independent step-time ceiling defaults to zero, so a functional pass does not
establish performance acceptance. The job is absent from `BENCHMARKS` until
site validation justifies enabling it. See
[the run procedure](../how-to/run-deepseek-v3-proxy.md).

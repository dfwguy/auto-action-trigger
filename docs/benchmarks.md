# Benchmark jobs (`jobs/$JOBS/`)

The job set is a directory: `jobs/nvl72/` ships, and `JOBS` in `SETTINGS`
selects which one `launch_job.sh` submits from. Everything below describes
`jobs/nvl72/`; a second platform is a second directory, not a second copy of
this framework.

`jobs/nvl72/` covers the single-node (SNT) rows of the
[AI Factory Testing Plan](https://gitlab-master.nvidia.com/nvis-npi/validation-mops/-/blob/main/ai_factory_testing_plan.md).
Which subset runs depends on the delivery methodology for the site — see the
commented catalog above `BENCHMARKS` in `SETTINGS`.

| Plan row | Job | Variants |
|----------|-----|----------|
| DCGM Diagnostics `-r 2` / `-r 3` / `-r 4` | `dcgm-r2`, `dcgm`, `dcgm-r4` | TTM / Hybrid / Exhaustive |
| nvbandwidth | `nvbandwidth` | all |
| NCCL Single Node, NVLink | `allreduce`, `alltoall` | all |
| NCCL Single Node, NVLink, SHARP required | `allreduce-forcesharp` | all |
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

Most of the default `BENCHMARKS` list has dependencies that are always
available: `dcgm` uses a host binary, and the NCCL jobs use the
`hpc-benchmarks` image that `build_containers.sh` pulls from the public catalog.
The exception is `nvbandwidth`, which is in the default list and comes from a
private NGC org — so a head node that has not run `./build_containers.sh -L`
has no image for it and it fails on every node. `./build_containers.sh -l` is
the check.

`mnubergemm` is not in `BENCHMARKS` at all. It is the burn-in phase (`BURNIN`,
gated by `RUN_BURNIN`, off by default), which the sequencer queues only after
every benchmark passes — see [settings.md](settings.md#burn-in).

Everything else needs one of three things first:

- **An image.** `nvloom` has no published image anywhere and exists only once
  `build_containers.sh -S` compiles it; `nvbandwidth` and `mnubergemm` are
  downloadable given [an NGC login](containers.md#logging-in-to-ngc).
- **Site values.** Jobs outside the default list ship with placeholders —
  interface names, the `ethr` server host, and the `fio` scratch directory. Set
  these per platform before adding the job to the list. The pass thresholds are
  *not* among them: they live in `parsers/$PARSERS/verdict.sh`
  (`VERDICT_MIN_TRIAD_MBS`, `VERDICT_MIN_TFLOPS_GEMM`, …), because a threshold
  set in the sbatch only ever applies to runs made after it was set.
- **A supported platform.** `nvsm` is **DGX only** — it ships with DGX OS and
  only carries platform definition files for DGX platforms, so on anything else
  it fails on every node and drains the cluster for a tool that was never going
  to run. It is out of the default list for that reason. On a DGX site it also
  needs a sudoers grant on every compute node — see [nvsm.md](nvsm.md).

## The allocation header

Every job in `jobs/nvl72/` asks for the whole node. That is what serializes the sweep
(see [sequencer.md](sequencer.md)) and what makes a bandwidth or latency number
mean anything: a benchmark sharing a node with another job is measuring the
other job.

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

### Queue priority

Every job states its own `#SBATCH --nice`. Slurm subtracts it from the job's
priority, so **higher is later** and `0` is the front of the queue. Three tiers:

| `--nice` | Jobs | Why |
|---|---|---|
| `0` | `dcgm`, `dcgm-r2`, `dcgm-r4` | fast, and they decide whether the rest of the sweep is worth running at all |
| `20` | every other benchmark | the sweep's own tier |
| `100000` | `mnubergemm` | burn-in, always last |

This is what lets the burn-in list be queued at the same time as the sweep
rather than gated behind it: a benchmark submitted while a burn-in is on the
node goes ahead of the burn-in runs still waiting, so the wait is one run
rather than twelve.

It lives in the job file, not in `SETTINGS` and not in `launch_job.sh`, for the
same reason `-t` and `--exclusive` do — it is part of how this job wants to be
scheduled, and stating it here means a job submitted **by hand** carries the
same priority as one the sequencer submits. `hpl` and `cublasmatmul` are
remediation jobs run by hand, and they still queue at `20` behind a dcgm gate.

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

### Two time limits, and the order they fire in

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
test, and doubling `~2 min` to four would cancel healthy `dcgm -r 2` steps.
Where a job configures its own run duration — `stressapptest`'s `RUN_SECONDS`,
`mnubergemm`'s `--time_to_run` — that is the estimate to double, not the plan's
figure for the row. Where a job runs several steps (`fio` and `ethr` per pass,
`nvsm`'s stress and health steps), each carries its own limit and they have to
**sum** to less than the walltime — `ethr` in particular sizes its walltime for
one interface, so adding a second to `IFACES` means raising `#SBATCH -t` too.

The three `dcgm` jobs bound their work with `timeout` instead of `srun --time`.
`dcgmi diag` runs in the batch script body rather than in a step — deliberately,
so it sees the job's GPUs without restating `--gres` — so there is no step for
`--time` to bound. `JOB_TIMEOUT` there is a `timeout(1)` duration (`40m`, not
`0:40:00`), and the job writes `timeout: killed after <n>` on 124 *or* 137,
which `VERDICT_RUN_ERRORS` matches the same way it matches Slurm's
`CANCELLED AT`. Both mechanisms buy the same property — the batch script
survives to write a marker — but prefer `--time` wherever there is a step: it is
Slurm's own accounting, and does not depend on a signal reaching the right
process.

### Preflight

Every job opens with a one-line `srun` that reports what the *step* holds:

```
preflight: <node> gpus=4 cores=144/144
```

and fails the job if it is not what was asked for. This is checked from inside a
step because that is the only place that can see it — a step is a different
cgroup from the batch script body, so a correct `AllocTRES` on the job tells you
nothing about what the workload will get. `jobs/nvl72/example.sbatch` carries the full
reasoning, including why the passing line is worded the way it is: several parse
blocks and `verdict.sh` grep the same file case-insensitively for
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

## Adding a new benchmark

1. Copy `jobs/nvl72/example.sbatch` to `jobs/$JOBS/<name>.sbatch`. Its `#SBATCH` header and
   preflight block are part of what you are copying — see
   [the allocation header](#the-allocation-header).
2. Set `job_name=<name>` and optionally `totalRuns=N`.
3. Add your workload between the job and parse sections.
4. Set `STEP_TIMELIMIT` and `#SBATCH -t` per
   [the two time limits](#two-time-limits-and-the-order-they-fire-in), and pass
   the former to the workload's `srun --time`.
5. The parse section must `echo PENDING` if the workload ran and `echo FAIL` if
   it could not, as the last line — capture the exit status immediately after
   the workload with `rc=$?` and end the file with:

   ```bash
   echo "exit status: $rc"
   [[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL
   ```

   The `exit status:` line is what says *who* decided a `FAIL`. A non-zero
   there is the job's own verdict, with the cause somewhere in the log above;
   `exit status: 0` under a `FAIL` means the workload ran clean and the gate in
   `verdict.sh` rejected the output, so the reason is in the status check
   rather than in the file. The gate runs at status-check time and writes
   nothing back into the result, so without this line the two are
   indistinguishable in the file. Keep the prefix identical across jobs, keep
   it before the marker — `verdict.sh` reads the last line — and keep the words
   fail, warn and error out of it, since several gates sweep the whole file for
   those case-insensitively.
6. Add a gate for `<name>` to the `case` in `parsers/$PARSERS/verdict.sh`. Without one it falls
   through to `_v_gate_generic`, which only checks for common crash signatures
   and cannot know what your job's output is supposed to look like.
7. Add a fixture under `tests/fixtures/` and a line to `tests/verdict-test.sh`.
8. Add `<name>` to the `BENCHMARKS` in `SETTINGS`.

## Where a pass is decided

An sbatch does **not** decide whether its own result is good. It reports only
whether it ran (`PENDING`) or could not (`FAIL`). `DONE` is derived by
`verdict.sh`, which is read by `launch_job.sh`, `status-check.sh` and
`daily-report.sh` every time they look at a result — it is never written
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

### Judge what the tool means, not what it says

The mirror image of that rule, and the more expensive one. A failure string
matched without regard to *where* it appears will match the tool's own healthy
output, and then the job cannot pass anywhere.

`nvbandwidth` did exactly this. MOP section 6.2 asks it to fail on "any `N/A`
where a peer transfer was expected", which the parse block implemented as
`grep -iE "N/A"` over the whole file. But every peer matrix prints `N/A` down
the diagonal, where a GPU would be talking to itself:

```
memcpy CE GPU(row) -> GPU(column) bandwidth (GB/s)
           0         1         2         3
 0       N/A    767.64    770.54    770.26
```

So the job failed every node with more than one GPU, on results that were
perfect. The fix is positional — `N/A` is expected on the diagonal of a
`GPU(row)` × `GPU(column)` matrix and nowhere else — and it lives in
`_v_gate_nvbandwidth`.

Two things made this worse than an ordinary wrong rule, and both are reasons the
gate belongs in `verdict.sh`:

- **A self-reported `FAIL` is never re-judged.** `DONE` is re-derived on every
  read, but `FAIL` is taken at its word, because it means "the job could not
  run" — the log is the diagnosis. Fixing the rule in the sbatch would have left
  every already-condemned result condemned. Those have to be re-run.
- **It failed closed and looked like a hardware finding.** A node reporting
  `nvbandwidth: FAIL` reads as a bad node, not as a bad grep.

Prefer the narrowest match that can only mean a fault: the string the tool
prints for the failure, matched case-sensitively where it is a fixed word, and
anchored where position carries the meaning. `_v_gate_nvsm` is currently the
loosest gate here — a case-insensitive sweep for `fail`/`error` over the whole
file — and it carries a comment saying so, because no healthy `nvsm show health`
output has been captured to narrow it against. That is the shape of an unpaid
debt in this file, not a pattern to copy.

`allreduce-forcesharp` exists for the same reason, one level down. Both it and
`allreduce` set `NCCL_NVLS_ENABLE=1`, and on the NCCL 2.29 in this image that
is identical to the shipped default of 2: a node whose NVLS *allocation* fails
errors out, but a node with no NVLS *support at all* falls back to a GPU-side
algorithm without saying so. `allreduce` therefore passes on a node where SHARP
never ran, at whatever bandwidth the fallback happens to reach. Adding
`NCCL_ALGO=NVLS` removes the fallback: NVLS becomes the only algorithm NCCL may
pick, so an unsupported node fails in `ncclCommInitRank` instead. The pair
answers two different questions — `allreduce` asks whether the collective works,
`allreduce-forcesharp` asks whether the switch offload is the thing doing it.

Its own question is settled before any bandwidth is measured: when it produces
a summary line at all, it ran the way `allreduce` is meant to. The floor is
therefore a second check rather than the point of the job, and it is set at
670 rather than the 683 `allreduce` uses — pinning the algorithm costs a little
bandwidth even where NVLS is what NCCL would have picked anyway, and the
unpinned floor fails healthy nodes for that difference. A failure here is a
real answer, not a broken job — expect the NCCL
init error in full in the result file. `NCCL_ALGO` is also the first line to
suspect if it starts failing fleet-wide right after an image change: which
algorithms exist behind that name is a property of the NCCL build, not of the
fabric.

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

`jobs/nvl72/nccl-hca.sh` does two separate things, and conflating them is what cost
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

Bandwidth floors live in `VERDICT_MIN_PEAK_BW_*` at the top of
`parsers/nvl72/verdict.sh` — 683, 670 and 623 GB/s for the NVLink-scope
`allreduce`, `allreduce-forcesharp` and `alltoall`, and 43 GB/s for each of the
`-nonvlink` pair. They
all read the same number: out-of-place busbw at the
largest message size actually run. That is also the figure `daily-report.sh`
prints in those columns, so a value in the report can be compared against the
floor directly.

The `# Avg bus bandwidth` summary line is required to be present, as evidence
the run finished, but is not judged. It averages every message size and comes
out roughly half the largest-size figure on the same run, so a floor stated
against it could not be checked against anything an operator is looking at.

The `allreduce` and `alltoall` floors were set from known-good runs on this
platform. The `-nonvlink` 43 was not: it is what the compute-plane HCAs are
expected to sustain, and it sits above every IB-scope result captured so far — the fixture
that used to be `alltoall-nonvlink__good-ib` measures 32.35 and is now a
below-floor case. Read a full `daily-report.sh` before acting on drains from
these two jobs. A handful of nodes under the floor is a fabric problem; every
node landing in the thirties is the floor being wrong.

Run `tests/verdict-test.sh` after changing a gate. It checks
`parsers/nvl72/verdict.sh` against captured result files, including a real
socket run and a real healthy `nvbandwidth` run, and asserts the reason as well
as the verdict.

Coverage is uneven and worth knowing before you trust a gate. `allreduce`,
`alltoall`, their `-nonvlink` pair, `dcgm`, `nvbandwidth` and `example` have
fixtures. The rest — `allreduce-forcesharp`, `nvloom`, `cublasmatmul`, `stream`, `stressapptest`,
`memtester`, `stress-ng`, `fio`, `ethr`, `hpl`, `llm-pretrain`, `mnubergemm`
and `nvsm` — do not, because no result file from this platform has been captured
for them; their rules were carried over from the parse blocks that used to live
in each sbatch and have never been run against real output. When one of those
jobs is first enabled at a site, capture its result file as a fixture before
trusting the verdict.
`tests/health-runner-test.sh` is the equivalent for the health side: it runs
the check loop out of `node_health.sh` against a synthetic check set and
asserts which mismatches reach the drain reason.

`tests/recover-test.sh` covers `slurm-recovery.sh` — the drain classification
and every gate in front of a resume — against stubbed `sinfo`, `scontrol`,
`squeue`, `systemctl` and `nvidia-smi`. Its operator cases matter most: a
mistake there resumes a node somebody took out of service, and that is
invisible from every direction afterwards.

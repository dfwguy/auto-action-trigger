# Choose and enable benchmarks

`BENCHMARKS` in `SETTINGS` is the ordered list of jobs the sweep runs. The
catalog of what is available is [reference/jobs.md](../reference/jobs.md).

## Check the dependencies first

The `dcgmi-r*` jobs use a host binary, and the NCCL jobs use the
`hpc-benchmarks` image that `build_containers.sh` pulls from the public catalog.
The default also includes `nvbandwidth`, which comes from a private NGC org,
and the two LLM jobs, which require a prepared LLMB installation. A missing
dependency makes its job fail on every node. Check both before enabling a
sweep:

```bash
./build_containers.sh -a arm -l      # what is actually present
./build_llmb.sh -l                   # resolve and validate the LLMB install
```

Everything else needs one of three things first:

- **An image.** `nvloom` has no published image anywhere and exists only once
  `build_containers.sh -S` compiles it; `nvbandwidth` and `mnubergemm` are
  downloadable given an NGC login. See
  [build-containers.md](build-containers.md).
- **Site values.** Jobs outside the default list ship with placeholders —
  interface names, the `ethr` server host, and the `fio` scratch directory. Set
  these per platform before adding the job to the list. The pass thresholds are
  *not* among them: they live in `parsers/$PARSERS/verdict.sh`
  (`VERDICT_MIN_TRIAD_MBS`, `VERDICT_MIN_TFLOPS_GEMM`, …), because a threshold
  set in the sbatch only ever applies to runs made after it was set.
- **A supported platform.** `nvsm` is **DGX only**. See
  [enable-nvsm.md](enable-nvsm.md).

`mnubergemm` is not in `BENCHMARKS` at all. It is the burn-in phase (`BURNIN`,
gated by `RUN_BURNIN`, off by default).

## Pick a list

**Default — ships as written.** Assumes an NGC login for `nvbandwidth` and a
prepared LLMB installation:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 dcgmi-r4 nvbandwidth allreduce \
            allreduce-forcesharp alltoall allreduce-nonvlink \
            alltoall-nonvlink llm-pretrain llm-pretrain-solo"
```

Three DCGM levels: `-r 1` is software-only and nearly free, `-r 3` is the deep
normal-sweep gate, and `-r 4` adds sustained thermal and power stress.

**No credentials needed.** Drop `nvbandwidth` from the list, and build only the
one image the rest need:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r3 allreduce allreduce-forcesharp alltoall \
            allreduce-nonvlink alltoall-nonvlink"
```

```bash
./build_containers.sh -a arm hpc-benchmarks
```

**Everything that needs no image beyond `hpc-benchmarks` and no DGX.** Runs as
shipped on any site, credentials or not:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r2 dcgmi-r3 dcgmi-r4 allreduce \
            allreduce-forcesharp alltoall allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng \
            stressapptest fio ethr llm-pretrain"
```

**Everything** — the Exhaustive tier plus the optional jobs. Read the notes
above first: `nvsm` drains a non-DGX cluster on every node, and `nvloom` has no
published image at all. Both `hpl` and `cublasmatmul` are remediation tools
meant to be submitted by hand against one suspect node, not swept across a
fleet. A sweep of this list takes days per node, and every job holds the whole
node while it runs:

```bash
BENCHMARKS="dcgmi-r1 dcgmi-r2 dcgmi-r3 dcgmi-r4 nvbandwidth allreduce \
            allreduce-forcesharp alltoall nvsm allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng stressapptest \
            fio ethr nvloom mnubergemm llm-pretrain hpl cublasmatmul"
```

## Order matters

Everything in the list without a passing result is queued once an hour, in
listed order, one job at a time. So put the cheap gates first and anything with
no fabric dependency where a fabric problem cannot push it to the back.

A name with no `jobs/$JOBS/<name>.sbatch` behind it is skipped with a line in
the trace rather than failing — so a job set that does not have every listed
benchmark is not an error, it just runs fewer of them.

## Turn burn-in on

```bash
RUN_BURNIN=yes
BURNIN="mnubergemm"
```

The image has to be there **before** the switch is flipped — turning burn-in on
at a site that never downloaded `mnubergemm` means a fleet-wide failure on the
first cycle instead of a burn-in. A node is then under burn-in for about three
days. See
[explanation/sequencing.md#two-lists](../explanation/sequencing.md#two-lists).

## Try one without committing to it

`--test` runs a job in place of the configured lists, without editing
`SETTINGS`:

```bash
clush -w ink50-dh01-h02-11 '/home/cmods/bringup/actions/launch_job.sh -t ethr -v'
pdsh -R ssh -w ink50-dh01-h02-11 '/home/cmods/bringup/actions/launch_job.sh -t ethr -v'
```

That is the right way to check a job works at a site before adding it — adding
it to `BENCHMARKS` to try it once changes what every node is expected to pass
and what the daily report calls a hole. See
[run-a-job-by-hand.md](run-a-job-by-hand.md#running-a-job-that-is-not-in-the-list).

# Settings (`SETTINGS`, `SETTINGS.default`)

Everything configurable lives in one file at the bringup root. Two files,
strictly:

| File | What it is |
|------|------------|
| `SETTINGS.default` | Ships with the framework. Tracked in git, replaced by every tarball drop. |
| `SETTINGS` | The site's own copy. Git-ignored, never written by an upgrade. |

`settings.sh` reads `SETTINGS` if it exists, and `SETTINGS.default` if it does
not. They are not layered — a site's `SETTINGS` is the whole answer.

```bash
cp SETTINGS.default SETTINGS
```

What *is* layered is the defaults inside `settings.sh`: any key a settings file
leaves unset is filled in there. So a `SETTINGS` only has to carry the lines the
site actually changed, and a `SETTINGS` written against an older release does
not break when a new key is added — the variable gets its shipped value rather
than an empty string. That backfill is the reason this is safe to upgrade
through: without it, adding a key would leave every existing site with a path
built from an empty variable, and the failure surfaces as "no benchmarks found"
rather than as anything naming settings.

Editing `SETTINGS.default` in place works until the next tarball drop
overwrites it. Do it once and forget, and the site's configuration silently
reverts on an upgrade.

## Which set of things to run

Three settings each name a subdirectory:

| Setting | Directory | Contents |
|---------|-----------|----------|
| `JOBS` | `jobs/$JOBS/` | The `.sbatch` files `launch_job.sh` submits — see [benchmarks.md](benchmarks.md) |
| `HEALTHCHECKS` | `health-checks/$HEALTHCHECKS/` | One file per check, run by `node_health.sh` — see [health-checks.md](health-checks.md) |
| `PARSERS` | `parsers/$PARSERS/` | `verdict.sh`: the pass/fail rule and the bandwidth floors every result is judged against |

All three ship as `nvl72`. They are separate variables rather than one
`PLATFORM` because they do not have to move together: a site can run the nvl72
job set against a health-check set trimmed for its hardware, and a new platform
usually starts by reusing the existing parsers.

`settings.sh` exports `JOBS_DIR`, `HEALTHCHECKS_DIR` and `PARSERS_DIR` already
joined to the bringup root, so no script has to remember which variable indexes
which directory.

## The benchmark list

`BENCHMARKS` is the ordered list of jobs to run. Everything in it without a
passing result is queued once an hour, in listed order. A name with no
`jobs/$JOBS/<name>.sbatch` behind it is skipped with a line in the trace rather
than failing — so a job set that does not have every listed benchmark is not an
error, it just runs fewer of them.

### Available single-node jobs (`jobs/nvl72/`)

Jobs are organized by AI Factory Testing Plan (SNT) tier:

| Job | Description | Tier |
|-----|-------------|------|
| `dcgm-r2` | TTM DCGM gate (`dcgmi diag -r 2`) | TTM |
| `dcgm` | Hybrid DCGM gate (`dcgmi diag -r 3`) | Hybrid |
| `dcgm-r4` | Exhaustive gate (`dcgmi diag -r 4`) | Exhaustive |
| `nvbandwidth` | HBM / PCIe / NVLink bandwidth | Hybrid / Exhaustive |
| `allreduce` `alltoall` | NCCL single-node, NVLink scope | Hybrid / Exhaustive |
| `allreduce-nonvlink` `alltoall-nonvlink` | NCCL single-node, no NVLink (HCA loopback) | Hybrid / Exhaustive |
| `nvsm` | NVSM stress — DGX only; see note below | Hybrid / Exhaustive |
| `stream` `memtester` | CPU memory bandwidth + DRAM integrity | Exhaustive |
| `stress-ng` | CPU stress | Exhaustive |
| `stressapptest` | Extended memory integrity | Exhaustive |
| `fio` | Local NVMe / shared storage | Exhaustive |
| `ethr` | North-south management + storage NIC | Exhaustive |
| `nvloom` | MNNVL fabric — optional / exploratory | Exhaustive |
| `mnubergemm` | Burn-in | Hybrid / Exhaustive |
| `llm-pretrain` | Single-node LLM pre-training workload gate | Hybrid / Exhaustive |
| `hpl` `cublasmatmul` | Remediation-only single-node GEMM — run by hand | Remediation |

### Choosing a `BENCHMARKS` list

Pick the set matching the delivery methodology. The default holds only jobs
whose dependencies are always available: `dcgm` uses a host binary, and the
NCCL jobs use the `hpc-benchmarks` image, which `build_containers.sh` pulls
from the public catalog. Jobs whose image has to be built or obtained
(`nvbandwidth`, `nvloom`, `mnubergemm`) are covered in
[containers.md](containers.md) and are added here once their image exists.

**Default — ships as written:**
```bash
BENCHMARKS="dcgm allreduce alltoall allreduce-nonvlink alltoall-nonvlink"
```

**Everything that needs no image beyond `hpc-benchmarks` and no DGX** — the
same list minus `nvsm`, `nvbandwidth`, `nvloom`, `mnubergemm` and the two
remediation GEMMs. This one runs as shipped on any site:
```bash
BENCHMARKS="dcgm-r2 dcgm dcgm-r4 allreduce alltoall allreduce-nonvlink \
            alltoall-nonvlink stream memtester stress-ng stressapptest \
            fio ethr llm-pretrain"
```

**Everything** — the Exhaustive tier plus the optional jobs. Nothing stops you
running this, but read the notes above first: `nvsm` drains a non-DGX cluster
on every node, and `nvbandwidth`, `nvloom`, and `mnubergemm` each need an image
that does not exist until CONTAINERS builds it. Both `hpl` and `cublasmatmul`
are remediation tools meant to be submitted by hand against one suspect node,
not swept across a fleet. A sweep of this list takes many hours per node, and
every job holds the whole node while it runs. `mnubergemm` always fails in the
CONTAINERS build — it has no source and no registry to pull from — so the
build exits non-zero even when the others built cleanly:
```bash
BENCHMARKS="dcgm-r2 dcgm dcgm-r4 nvbandwidth allreduce alltoall nvsm \
            allreduce-nonvlink alltoall-nonvlink stream memtester \
            stress-ng stressapptest fio ethr nvloom mnubergemm \
            llm-pretrain hpl cublasmatmul"
```

### The `nvsm` note

`nvsm` is deliberately NOT in the default list. It is a DGX-only tool that
ships with DGX OS and only carries platform definition files for DGX platforms,
so on anything else it exits before doing any work ("Failed to find a matching
definition file for this platform") and fails identically on every node — which
means a whole-cluster drain for a tool that was never going to run. GPU stress
is already covered by `dcgm` and `mnubergemm`.

Add it back on a DGX site, where it also needs a passwordless sudoers grant on
every compute node. Put it between the NVLink NCCL jobs and the no-NVLink ones
so a fabric problem does not push a GPU stress test to the back of the queue —
`nvsm` has no fabric dependency and should report early:

```bash
BENCHMARKS="dcgm allreduce alltoall nvsm allreduce-nonvlink alltoall-nonvlink"
```

See [nvsm.md](nvsm.md) for both requirements.

## Container images

`CONTAINERS` is the list `build_containers.sh` builds when no image is named on
the command line. It ships as `hpc-benchmarks`, which is what the default
`BENCHMARKS` list needs and nothing more; add an image here at the same time as
you add the job that uses it.

| Image | Jobs that use it | Source |
|-------|-----------------|--------|
| `hpc-benchmarks` | `allreduce`, `alltoall`, both `-nonvlink` variants, `hpl`, `cublasmatmul`, `stream` | Public NGC image |
| `nvbandwidth` | `nvbandwidth` | Private NGC org (needs a login); source build only with `-S` |
| `nvloom` | `nvloom` | No published image; two-pass source build, and only with `-S` |
| `mnubergemm` | `mnubergemm` | Private NGC org (needs a login); NVIDIA-internal, no source build exists |

`dcgm` and `nvsm` are not in this table — they run host binaries and need no image.

```bash
CONTAINERS="hpc-benchmarks"            # default — what the default BENCHMARKS needs
CONTAINERS="hpc-benchmarks nvbandwidth mnubergemm"   # everything downloadable, given an NGC login
CONTAINERS="hpc-benchmarks nvbandwidth nvloom"       # adds the source build — run with -S
CONTAINERS=""                          # build nothing — images already in containers/ or obtained another way
```

An explicitly empty `CONTAINERS=""` means "build nothing" and is left that way
— it is the one setting where empty is a real answer rather than an omission,
so `settings.sh` backfills it only when the key is absent altogether. See
[containers.md](containers.md#which-images-get-built).

`build_containers.sh -A` builds everything the script knows about regardless of
this setting, and naming images as arguments overrides it.

## Drains

```bash
DRAIN_AFTER_FAILED_HEALTH_CHECK=no   # node_health.sh: mismatch against the baseline
DRAIN_AFTER_FAILED_BENCHMARK=no      # launch_job.sh: failed sweep, and MAX_JOB_HOURS
```

Both ship off. These replace the old `NODRAIN` file, which is gone; a `NODRAIN`
left over from an earlier deployment now does nothing.

Anything not affirmative reads as off — `yes`, `true`, `1` and `on` enable, and
everything else, including a typo and including empty, disables. For two
switches that decide whether nodes get taken out of service, an unreadable
value has to mean "don't".

`DRAIN_AFTER_FAILED_HEALTH_CHECK` is the one to leave off longest. A health
check drains on any diff against `valid-config/default`, so a baseline taken
from a node that is itself slightly off, or one check that is per-rack rather
than per-cluster, drains the entire cluster on the first monitoring cycle.
Bring it up only after `bash health-check.sh --summary` reads clean across the
fleet.

The full operational picture — what changes when they are off, what does not,
and which one to turn on first — is in
[operations.md](operations.md#disabling-drains).

## Retry and drain policy

| Setting | Default | Meaning |
|---------|---------|---------|
| `RETRY_INTERVAL_HOURS` | `1` | Hours between sweeps, measured from the newest result file on the node |
| `MAX_JOB_HOURS` | `6` | A benchmark `RUNNING` longer than this drains the node |
| `DRAIN_WINDOW_MINUTES` | `15` | Only failures newer than this drain |
| `DRAIN_MARKER` | `auto-retry` | Written into every drain reason this framework issues; only drains carrying it are ever cleared automatically |

`DRAIN_WINDOW_MINUTES` has to sit above the BCM monitoring interval or the
drain is missed entirely, and well below `RETRY_INTERVAL_HOURS`. Its purpose is
that without it, `launch_job.sh` would re-drain from stale result files on every
monitoring cycle — a node an operator had just resumed would be pulled straight
back out of service.

`DRAIN_MARKER` is what makes an operator drain survive. `launch_job.sh` will not
queue work behind a drain that does not carry it, and will not clear one.

## Accounts and paths

| Setting | Default | Meaning |
|---------|---------|---------|
| `JOB_USER` | `cmods` | The account Slurm jobs are submitted as, and the owner `results/` and `logs/` are handed to |
| `BRINGUP_HOME` | `/home/cmods/bringup` | Where this checkout lives on the cluster |

`BRINGUP_HOME` is documentation for the BCM actions rather than something they
read: `node_health.sh` and `launch_job.sh` carry the path literally, because BCM
invokes them with no working directory to infer one from and they have to find
`settings.sh` before they can read anything from it. Deploying elsewhere means
editing `home=` at the top of both, and this setting to match. Every other
script resolves its own location and ignores it.

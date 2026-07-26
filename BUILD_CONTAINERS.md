# Containers for the benchmark jobs

`build_containers.sh` builds every container image the jobs need as a local
`.sqsh` in `/home/cmods/bringup/containers/`. `actions/file_copy.sh` rsyncs
that directory to `/tmp/containers/` on each node, and every job prefers the
node-local copy. Nothing is pulled from a registry at job start.

```bash
./build_containers.sh          # build everything missing
./build_containers.sh -l       # what is present, what is not
```

Run it on the headnode, once per CPU architecture in the cluster.

---

## Why local images

Jobs could name a registry URI directly — `docker://nvcr.io#nvidia/hpc-benchmarks:26.02`
— and enroot would pull it on first use. Three reasons we do not:

- **Every node pulls separately.** Enroot's pull cache is per node, so a
  first sweep across a rack is one full image download per node.
- **A registry outage stops testing.** Bringup often happens before the
  cluster has reliable external network, and the private NGC org behind the
  nvbandwidth image needs credentials distributed to every compute node.
- **Two of the images cannot be pulled at all.** nvloom publishes only a
  sample Dockerfile, and mnubergemm is internal.

The registry URI is still in each job as a commented alternative, so a node can
fall back by hand if an image is missing.

## How the caching works

Three layers, each avoiding a different transfer:

| Layer | Path | Populated by | Avoids |
|-------|------|--------------|--------|
| Build cache | `/tmp/enroot-cache/$UID`, docker's layer store | `build_containers.sh` | Re-pulling layers on rebuild |
| Shared copy | `/home/cmods/bringup/containers/` | `build_containers.sh` | Per-node registry pulls |
| Node-local cache | `/tmp/containers/` | `actions/file_copy.sh` | Reading the image over NFS at every job start |

The last one is the one that matters at run time. A `.sqsh` is mounted, not
copied, so a job pointed at the NFS path streams the image over NFS for the
whole run — with several nodes starting the same benchmark at once, that is the
slowest part of a sweep. Each job resolves its image as:

```bash
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
```

so a node the rsync has not reached yet still runs, just off NFS.

The build side keeps `ENROOT_CACHE_PATH` and `ENROOT_TEMP_PATH` on local disk
(`/tmp`) rather than their defaults under `$HOME`, which is NFS here — an
import otherwise writes a multi-gigabyte layer tree over the wire and reads it
straight back. Override with the environment variables of the same name if
`/tmp` on the headnode is small.

`ENROOT_DATA_PATH` and `ENROOT_RUNTIME_PATH` go under `/tmp` for a different
reason: enroot creates both at startup for every subcommand, `import` included,
and their compiled defaults (`/var/lib/enroot`, `/run/enroot`) are root-only.
The compute nodes get writable values from `/etc/enroot/enroot.conf`; the
headnode does not, so without the override the script fails on `mkdir` before
it pulls anything. Do not work around that by running the build as root — the
`.sqsh` files would come out root-owned, and `file_copy.sh` and the jobs read
them as `cmods`.

`file_copy.sh` uses `rsync -a`, not `-r`. Without `-t` (implied by `-a`) the
destination mtimes are the copy time, the size+mtime quick check never matches,
and every monitoring cycle re-transfers the whole directory.

## Images

| Image | File | Source | Used by |
|-------|------|--------|---------|
| hpc-benchmarks | `nvidia+hpc-benchmarks+26.02-<arch>.sqsh` | public NGC pull | `allreduce`, `alltoall`, both `-nonvlink`, `hpl`, `cublasmatmul`, `stream` |
| nvbandwidth | `nvbandwidth-v0.9-<arch>.sqsh` | private NGC org, else built from source | `nvbandwidth` |
| nvloom | `nvloom-v2.0.0-<arch>.sqsh` | built from the upstream sample Dockerfile | `nvloom` |
| mnubergemm | `mnubergemm-26.03-v1.17-arm.sqsh` | internal channel only | `mnubergemm` |

Jobs not listed need no container at all — `dcgm*`, `nvsm`, `stress-ng`,
`memtester`, `stressapptest`, `fio`, and `ethr` run a host-installed binary.

`<arch>` is `arm` or `x86`, defaulting to `uname -m` on the machine that built
the image. This is a **CPU** architecture split, not a GPU-generation one: Grace
and Vera are `aarch64`, Intel and AMD hosts are `x86_64`. An image built for one
does not run on the other, and the output is named after its target, so both can
live in the same directory.

## Building ARM images on an x86 headnode

The nodes have no route to the internet, so everything is fetched on the
headnode and reaches them over NFS and `file_copy.sh`. When the headnode is x86
and the nodes are ARM, pass the target explicitly:

```
./build_containers.sh -a arm            # or ARCH=arm ./build_containers.sh
```

**Registry pulls cross-build for free.** `enroot import` picks the matching
entry out of the image's manifest list, downloads those layers, untars them and
runs `mksquashfs`. Nothing from inside the image is ever executed, so the host
architecture is irrelevant. This covers `hpc-benchmarks` and `nvbandwidth`'s NGC
path — six of the ten containerised jobs — and finishes on the headnode with no
second pass. The script passes `--arch arm64`; enroot matches that verbatim
against `.platform.architecture`, so an image published x86-only will fail here
rather than silently hand back the wrong binaries.

**Source builds are split in two.** `nvloom` and `nvbandwidth`'s fallback have
to compile, and the only ARM machines are the compute nodes, which have no
internet. So the fetch happens where the network is and the compile happens
where the right CPU is. No emulation and no docker anywhere.

## The two-pass source build

```
./build_containers.sh -a arm -F nvloom      # headnode: fetch, compile nothing
srun -N1 ./build_containers.sh -B nvloom    # ARM node: compile, produce the .sqsh
```

`-F` stages three things into `/home/cmods/bringup/container-src/<image>/`:

| | |
|---|---|
| `base-arm.sqsh` | the CUDA devel base, imported with `--arch arm64` |
| `src/` | the upstream checkout at the pinned tag |
| `debs/` | the arm64 packages the build needs, plus a `Packages` index |
| `build.sh` | generated from `spec()` — the package list and build steps |

`-B` then does `enroot create` from the base, bind-mounts those read-only,
runs `build.sh` inside, and `enroot export`s the result straight to the final
`.sqsh` in `containers/`. Everything downstream is unchanged, because the
output is the same file it always was.

### Why the package staging is the awkward part

Both upstream Dockerfiles start with `apt-get install`, which on a node with no
route out will fail. The packages therefore have to come from the headnode —
which is the wrong architecture to run apt for, and configured for its own
release besides.

`fetch_debs()` gets around this by running apt inside a *native, throwaway*
`ubuntu:24.04` container with a private state directory and
`APT::Architecture=arm64`. Because arm64 looks native to that apt, the resolver
never hits the co-installability rules that make ordinary foreign-architecture
downloads fail — and since resolving and downloading never execute any of the
packages, none of it needs emulation. The result is turned into a real apt
repository with `apt-ftparchive packages`, so the node side resolves against it
normally rather than us guessing a `dpkg -i` order.

One refinement worth knowing about: apt's status file is seeded with the base
image's own package list, pulled out with `unsquashfs` (which reads a path out
of a `.sqsh` without mounting it, so it stays unprivileged). That way apt
stages only what the image is actually missing. If `unsquashfs` is unavailable
the script says so and falls back to staging the full dependency closure —
correct either way, just a much larger download.

### Trade-offs

The exported image is the CUDA **devel** base with the binary installed, where
upstream's Dockerfile copies the binary into a slim runtime stage. That makes
the `.sqsh` substantially larger, and `file_copy.sh` rsyncs it to every node.
The reason is that a multi-stage build needs a builder, and the whole point
here was to not require one; if the size becomes a problem the fix is a second
staged base image and a copy step, not a return to docker.

The staging directory is shared and mounted read-only during the build, so the
`-B` pass can be run on several nodes without them interfering. It is only
worth doing once per architecture, though — the output is identical.

If any of this is more trouble than it is worth, the escape hatch is unchanged:
build the two images on any ARM box with internet and drop the `.sqsh` files
into `containers/` by hand. Nothing downstream cares which machine produced
them.

`mnubergemm` is unaffected — it is internal, ARM-only, and imported by hand
whatever the headnode is.

## Prerequisites

- `enroot` on the headnode, and on the compute nodes for the `-B` pass (pyxis
  already depends on it there, so this is a given).
- `squashfs-tools` for `unsquashfs` on the headnode — optional, see above.
- Write access to `/home/cmods/bringup/containers/` and `container-src/`.
- No docker, anywhere.
- An NGC API key if pulling from the private org, in `ENROOT_CREDENTIALS`
  (`~/.config/enroot/.credentials`):
  `machine nvcr.io login $oauthtoken password <API_KEY>`.

## Options

```
-f            rebuild even if the .sqsh is already there
-l            list images and whether they are present, build nothing
-d DIR        write somewhere other than /home/cmods/bringup/containers
-a ARCH       build for arm or x86 rather than this machine
-F            fetch pass only (headnode); compile nothing
-B            build pass only (compute node); fetch nothing
```

Options must come before image names — `getopts` stops at the first
non-option argument.

Environment: `CONTAINER_DIR` (same as `-d`), `STAGE_DIR` (source staging,
default `/home/cmods/bringup/container-src`), `ARCH` (same as `-a`), `WORKDIR`
(scratch, default `/tmp/container-build-$UID`), `ENROOT_CACHE_PATH`,
`ENROOT_TEMP_PATH`, `ENROOT_DATA_PATH`, `ENROOT_RUNTIME_PATH`.

Imports go to a dot-prefixed temp name and are moved into place only on
success, so an interrupted run never leaves a truncated `.sqsh` for a job to
mount. Source checkouts are reused and refreshed rather than re-cloned.

---

## Per-image notes

### hpc-benchmarks

Public NGC catalog image, no credentials needed. Six jobs use it, so it is the
one with the most to gain from a single local copy.

### nvbandwidth

Upstream: [github.com/NVIDIA/nvbandwidth](https://github.com/NVIDIA/nvbandwidth)
(v0.9). No image on the public catalog.

The script first tries the prebuilt image in NGC org `0948245400141054`, which
`incubation/nvbandwidth-single-node-mop.md` in the validation-mops repo
references. A `401`/`403` there means no org access, and it falls back to
building v0.9 from the public source — a small CMake project, a few minutes.
The generated Dockerfile bases on `nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04`;
edit `NVBANDWIDTH_CUDA` in the script if the driver on the nodes is older, since
a CUDA base newer than the driver fails at run time, not at build time.

To enable the job, add `nvbandwidth` to `benchmarks=` in
`actions/launch_job.sh`.

The job's parse section enforces only the platform-independent criteria from
MOP §6.2 (coefficient of variation > 0.02, `N/A` peer transfers, tool errors).
The per-test `SUM` thresholds in §6.1 are the GB200 4-GPU baseline — add a
per-platform table before relying on them.

### nvloom

Upstream: [github.com/NVIDIA/nvloom](https://github.com/NVIDIA/nvloom). The repo
provides a `Dockerfile` and states outright that it is a sample you will want to
customize — it builds and runs as-is, but read it before trusting it on a new
platform. No image is published anywhere.

`nvloom_cli` runs under MPI with one process per GPU. The job already sets
`NVIDIA_VISIBLE_DEVICES=all` for the Pyxis GPU hook and deliberately omits
`--gpus-per-task` — nvloom assigns GPUs by MPI local rank, and scoping CUDA
devices per task causes `CUDA_ERROR_NO_DEVICE`.

The node-side prerequisite is IMEX, not fabricmanager:
`/dev/nvidia-caps-imex-channels/` must be populated and the IMEX service
healthy. On NVL72 the NVLink domain is managed by NMX-C on the switch trays and
the hosts run `nvidia-imex`; `node_health.sh` already covers those checks.

To enable, add `nvloom` to `benchmarks=` in `actions/launch_job.sh`. Scope 1
(basic health, ~10 min) is what runs by default; the Scope 2 burn-in `srun` is
present but commented, and needs `#SBATCH -t` raised above `BURN_IN_DURATION`
before use. nvloom is flagged *optional / exploratory* in the AI Factory Testing
Plan — Exhaustive only, not a required gate in any variant.

### mnubergemm

NVIDIA-internal, not publicly distributed and not buildable from anything we
have. `build_containers.sh` reports it as missing and prints the import command;
obtain the image through the internal channel for your platform and run:

```bash
enroot import -o /home/cmods/bringup/containers/mnubergemm-26.03-v1.17-arm.sqsh \
    dockerd://<image>:<tag>
```

Update `IMG` in `jobs/mnubergemm.sbatch` if the version or architecture suffix
differs.

Burn-in runs 24–72 hours per the plan, so it is not a candidate for the default
sequence — `MAX_JOB_HOURS` in `actions/launch_job.sh` defaults to 6 and will
drain the node with a timeout reason well before a real burn-in finishes. Raise
it before enabling.

---

## Verifying an image before enabling a job

```bash
srun --nodes=1 --nodelist=<node> --exclusive --gpus-per-node=4 \
     --container-image=/tmp/containers/<file>.sqsh \
     <binary> --help
```

If that resolves and runs, the job will too. If `/tmp/containers/` is empty on
the node, the rsync has not run yet — `actions/file_copy.sh` fires on the BCM
monitoring cycle, or run it by hand.

Check `results/<node>/<job>.txt` after the first real run — the last line is
`DONE` or `FAIL`, and the sequencer drains the node on `FAIL`.

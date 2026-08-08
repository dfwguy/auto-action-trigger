# Why the images are local, and how they get built

`build_containers.sh` builds the container images the jobs need as local `.sqsh`
files in `/home/cmods/bringup/containers/`. `actions/file_copy.sh` rsyncs that
directory to `/tmp/containers/` on each node, and every job prefers the
node-local copy. **Nothing is pulled from a registry at job start.**

Running it is [how-to/build-containers.md](../how-to/build-containers.md); the
image list is
[reference/settings.md#container-images](../reference/settings.md#container-images).

## Why local images

Jobs could name a registry URI directly —
`docker://nvcr.io#nvidia/hpc-benchmarks:26.02` — and enroot would pull it on
first use. Three reasons we do not:

- **Every node pulls separately.** Enroot's pull cache is per node, so a first
  sweep across a rack is one full image download per node.
- **A registry outage stops testing.** Bringup often happens before the cluster
  has reliable external network, and the private NGC org behind the nvbandwidth
  image needs credentials distributed to every compute node.
- **One of the images cannot be pulled at all.** nvloom publishes only a sample
  Dockerfile. mnubergemm can be pulled, but only from the private org.

The registry URI is still in each job as a commented alternative, so a node can
fall back by hand if an image is missing. It sits directly under the two lines
that pick the local copy:

```bash
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
```

The `#` in that URI is enroot's separator between the registry host and the
image path — not a comment marker, and not something to normalise into a `/`.
Written `docker://nvcr.io/nvidia/hpc-benchmarks:26.02` the whole string is an
image path on the default registry, and the pull fails against Docker Hub rather
than against `nvcr.io`. It is the easiest part of the line to lose when copying
it out to run something by hand.

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
(`/tmp`) rather than their defaults under `$HOME`, which is NFS here — an import
otherwise writes a multi-gigabyte layer tree over the wire and reads it straight
back.

`ENROOT_DATA_PATH` and `ENROOT_RUNTIME_PATH` go under `/tmp` for a different
reason: enroot creates both at startup for every subcommand, `import` included,
and their compiled defaults (`/var/lib/enroot`, `/run/enroot`) are root-only.
The compute nodes get writable values from `/etc/enroot/enroot.conf`; the
headnode does not, so without the override the script fails on `mkdir` before it
pulls anything. **Do not work around that by running the build as root** — the
`.sqsh` files would come out root-owned, and `file_copy.sh` and the jobs read
them as `cmods`.

`file_copy.sh` uses `rsync -a`, not `-r`. Without `-t` (implied by `-a`) the
destination mtimes are the copy time, the size+mtime quick check never matches,
and every monitoring cycle re-transfers the whole directory.

## What the container gets from the host

A containerised job does not inherit the node. Two things arrive only if
something asks for them, and both have cost real runs here.

**GPUs come in through the NVIDIA container hook, and the hook follows the
allocation.** Pyxis starts the container through enroot, and the hook
bind-mounts the GPU device nodes and driver libraries according to what the step
actually holds. A step holding no GPUs gets a container with no GPUs, and
`--exclusive` does not grant them — it is a job-level guarantee, and a step
inherits only what was explicitly requested. So every job that touches a GPU
states `--gres=gpu:N` in its `#SBATCH` header rather than leaving it implied;
see
[reference/jobs.md#the-allocation-header](../reference/jobs.md#the-allocation-header)
for the rest of that rule, including why `--cpus-per-task` is deliberately
absent.

**enroot gives the container a fresh `/dev`.** Whatever character devices the
host has, the container starts without them unless they are mounted in. The host
`/sys` does come along, so `/sys/class/infiniband` is populated inside the
container even when nothing under `/dev` is — which makes this failure
particularly good at looking like success:

- `ibv_get_device_list` returns nothing inside the container, because the HCA
  character devices are not there.
- NCCL logs `NET/IB : No device found.` and falls back to sockets.
- The run completes, writes a valid summary, and passes at roughly 1 GB/s.

That is how `allreduce-nonvlink` ran entirely over `bond0` for weeks. Checking
by hand from a shell on the node cannot catch it, because a `pdsh` — like any
other remote shell — puts you on the host, where the HCA list is complete and
correct the whole time. The `-nonvlink` jobs therefore
do two things: mount the devices with
`--container-mounts=/dev/infiniband:/dev/infiniband`, and ask the container
itself what it can see with `NCCL_HCA_PROBE` from `jobs/nvl72/nccl-hca.sh`,
whose last line `verdict.sh` gates on. **Ask the container, not the node** — see
[judging-benchmarks.md#host-hcas-are-not-container-hcas](judging-benchmarks.md#host-hcas-are-not-container-hcas).

The NVLink-scope jobs (`allreduce`, `alltoall`) deliberately do *not* mount
`/dev/infiniband`. That collective is meant to stay on NVLink and never reach
the network, so a node that has lost NVLink should fail rather than quietly
succeed over IB.

## Downloading is the default; source builds are opt-in

A bare run downloads and nothing else. If an image cannot be downloaded, the
script says why and stops rather than starting a compile.

| Image | Without `-S` | With `-S` |
|-------|--------------|-----------|
| `hpc-benchmarks` | public pull | same — nothing to build |
| `nvbandwidth` | private-org pull, else fail | private-org pull, else compile v0.9 from public source |
| `nvloom` | fails: nothing is published to pull | compile from the upstream sample Dockerfile |
| `mnubergemm` | private-org pull, else fail | same — no public source exists |

The default changed because the fallback was too expensive to trigger by
accident. A source build is minutes to tens of minutes, and on an x86 headnode
with ARM nodes it stops half way through and waits for a second pass on a
compute node — a lot to set in motion because a registry returned `401` when the
real answer was a login. `nvloom` waits for `-S` for the same reason even though
it has no download path at all: it names what it wants instead of committing you
to a build.

One side effect worth knowing: a download-only run no longer needs write access
to the staging directory (`STAGE_DIR`). Only `-S`/`-F` create it.

## Cross-building for ARM nodes from an x86 headnode

The nodes have no route to the internet, so everything is fetched on the
headnode and reaches them over NFS and `file_copy.sh`.

**Registry pulls cross-build for free.** `enroot import` picks the matching
entry out of the image's manifest list, downloads those layers, untars them and
runs `mksquashfs`. Nothing from inside the image is ever executed, so the host
architecture is irrelevant. This covers `hpc-benchmarks` and `nvbandwidth`'s NGC
path — six of the ten containerised jobs — and finishes on the headnode with no
second pass.

`enroot import -a` wants the *kernel's* spelling, `aarch64`, and runs it through
its own `debarch()` before matching `.platform.architecture` in the manifest
list. Handing it the Debian name, `arm64`, fails with "Unsupported architecture"
— which is why `build_containers.sh` keeps `enroot_arch()` and `deb_arch()` as
separate functions rather than one mapping. An image published x86-only fails
the import here rather than silently handing back the wrong binaries.

**Source builds are split in two.** `nvloom` and `nvbandwidth`'s fallback have
to compile, and the only ARM machines are the compute nodes, which have no
internet. So the fetch happens where the network is and the compile happens
where the right CPU is. No emulation and no docker anywhere.

### The two-pass source build

`-F` stages four things into `container-src/<image>/`:

| | |
|---|---|
| `base-arm.sqsh` | the CUDA devel base, imported with `--arch arm64` |
| `src/` | the upstream checkout at the pinned tag |
| `debs/` | the arm64 packages the build needs, plus a `Packages` index |
| `build.sh` | generated from `spec()` — the package list and build steps |

`-B` then does `enroot create` from the base, bind-mounts those read-only, runs
`build.sh` inside, and `enroot export`s the result straight to the final `.sqsh`
in `containers/`. Everything downstream is unchanged, because the output is the
same file it always was.

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
of a `.sqsh` without mounting it, so it stays unprivileged). That way apt stages
only what the image is actually missing. If `unsquashfs` is unavailable the
script says so and falls back to staging the full dependency closure — correct
either way, just a much larger download.

### Trade-offs

The exported image is the CUDA **devel** base with the binary installed, where
upstream's Dockerfile copies the binary into a slim runtime stage. That makes
the `.sqsh` substantially larger, and `file_copy.sh` rsyncs it to every node.
The reason is that a multi-stage build needs a builder, and the whole point here
was to not require one; if the size becomes a problem the fix is a second staged
base image and a copy step, not a return to docker.

The staging directory is shared and mounted read-only during the build, so the
`-B` pass can be run on several nodes without them interfering. It is only worth
doing once per architecture, though — the output is identical.

If any of this is more trouble than it is worth, the escape hatch is unchanged:
build the two images on any ARM box with internet and drop the `.sqsh` files
into `containers/` by hand. Nothing downstream cares which machine produced
them.

Imports go to a dot-prefixed temp name and are moved into place only on success,
so an interrupted run never leaves a truncated `.sqsh` for a job to mount.
Source checkouts are reused and refreshed rather than re-cloned.

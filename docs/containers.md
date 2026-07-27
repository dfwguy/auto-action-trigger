# Containers for the benchmark jobs

`build_containers.sh` builds the container images the jobs need as local
`.sqsh` files in `/home/cmods/bringup/containers/`. `actions/file_copy.sh`
rsyncs that directory to `/tmp/containers/` on each node, and every job prefers
the node-local copy. Nothing is pulled from a registry at job start.

```bash
./build_containers.sh -L       # log in to nvcr.io, once per machine
./build_containers.sh          # download the CONTAINERS list, whatever is missing
./build_containers.sh -l       # what is present, what is not, and the login state
```

Run it on the headnode, once per CPU architecture in the cluster.

Downloading is the normal path and, by default, the only one. Everything the
script knows about except `nvloom` is published on `nvcr.io`; compiling from
source is a fallback that happens only when `-S` asks for it. See
[Logging in to NGC](#logging-in-to-ngc) and
[Downloading vs building from source](#downloading-vs-building-from-source).

## Which images get built

`CONTAINERS` in `SETTINGS` is the list a bare run uses — the images this site's
`BENCHMARKS` actually need, and it ships as exactly that and nothing more.

```bash
CONTAINERS="hpc-benchmarks nvbandwidth mnubergemm"    # SETTINGS
```

Two of those three are in a private NGC org, so [`-L`](#logging-in-to-ngc) is a
prerequisite of the shipped configuration rather than an optional extra: with no
credentials the run builds `hpc-benchmarks`, fails the other two, and exits
non-zero. A site that does not want that dependency drops `nvbandwidth` from
**both** `CONTAINERS` and `BENCHMARKS` — dropping it from one alone is the
failure this section is about — and drops `mnubergemm` from `CONTAINERS` while
leaving `RUN_BURNIN=no`.

| Image | Needed by |
|-------|-----------|
| `hpc-benchmarks` | `allreduce`, `alltoall`, both `-nonvlink` variants, `hpl`, `cublasmatmul`, `stream` |
| `nvbandwidth` | `nvbandwidth` |
| `nvloom` | `nvloom` |
| `mnubergemm` | `mnubergemm` |

`dcgm` and `nvsm` are not in the table — they run host binaries and need no
image at all.

Add an image to `CONTAINERS` at the same time as you add the job that uses it
to `BENCHMARKS`. A job whose image is missing fails on every node, and it fails
at run time rather than at submission.

Two ways to override the setting for one run:

```bash
./build_containers.sh nvloom   # just this image, ignoring CONTAINERS
./build_containers.sh -A       # every image the script knows about
```

`-A` differs from the shipped `CONTAINERS` by one image, `nvloom`, which no
registry publishes at all — so `-A` implies `-S` and compiles it, which is a
much longer run than the three downloads. It needs the same
[login](#logging-in-to-ngc) for the two private-org images.

An explicitly empty `CONTAINERS=""` means "build nothing", and is respected as
written rather than defaulted back: a site whose images are already in place,
or which obtains them another way, does not need this script.

---

## Logging in to NGC

`hpc-benchmarks` and the CUDA base images are public. `nvbandwidth` and
`mnubergemm` live in private NGC org `0948245400141054`, and an import of
either without credentials fails with a `401`/`403` that enroot reports as a
plain import failure.

enroot has no `login` subcommand. It reads a netrc-style file before every
import and sends the matching entry as the registry's basic auth, so logging in
means writing one line into `~/.config/enroot/.credentials`:

```bash
./build_containers.sh -L                        # prompts, input hidden
NGC_API_KEY=nvapi-... ./build_containers.sh -L  # unattended
```

Either way the result is:

```
machine nvcr.io login $oauthtoken password <NGC_API_KEY>
```

`$oauthtoken` is the literal username NGC expects, not a shell variable — this
is why the file has to be written with a quoted heredoc if you do it by hand:

```bash
mkdir -p ~/.config/enroot
cat > ~/.config/enroot/.credentials <<'EOF'
machine nvcr.io login $oauthtoken password <NGC_API_KEY>
EOF
chmod 600 ~/.config/enroot/.credentials
```

Generate the key at
[org.ngc.nvidia.com/account](https://org.ngc.nvidia.com/account) — `-L` prints
that link, as does every private-org failure. Check that the org you are signed
in to is `0948245400141054`; a valid key for the wrong org fails exactly like
no key at all.

Notes on what `-L` does beyond the heredoc above:

- It replaces only the `nvcr.io` entry and keeps any others, so a site with a
  private mirror in the same file does not lose it.
- It writes through a `umask 077` temp file, so the key is never briefly world
  readable. `read -rs` keeps it out of terminal scrollback, and passing it in
  `NGC_API_KEY` keeps it out of shell history.
- It does **not** verify the key — nothing short of an import can. The next
  import is the check, which is why it suggests one.

`ENROOT_CONFIG_PATH` (or `XDG_CONFIG_HOME`) moves the file; the script follows
both. Only the machine doing the import needs it: images reach the nodes as
`.sqsh` files over NFS, so no credential is ever distributed to a compute node.

`-l` and `-h` both print whether an `nvcr.io` entry is present, and every
private-org failure prints the login state along with the fix.

## Downloading vs building from source

A bare run downloads and nothing else. If an image cannot be downloaded, the
script says why and stops rather than starting a compile:

```bash
./build_containers.sh nvbandwidth        # download only; fails with the login hint
./build_containers.sh -S nvbandwidth     # download, and compile from source if that fails
```

`-S` is what enables the fallback. `-F` and `-B` are the two passes *of* a
source build, so each implies `-S`. So does `-A`: it means "every image the
script knows about", and one of those cannot be downloaded at all, so asking
for it is asking for the build.

| Image | Without `-S` | With `-S` |
|-------|--------------|-----------|
| `hpc-benchmarks` | public pull | same — nothing to build |
| `nvbandwidth` | private-org pull, else fail | private-org pull, else compile v0.9 from public source |
| `nvloom` | fails: nothing is published to pull | compile from the upstream sample Dockerfile |
| `mnubergemm` | private-org pull, else fail | same — no public source exists |

The default changed because the fallback was too expensive to trigger by
accident. A source build is minutes to tens of minutes, and on an x86 headnode
with ARM nodes it stops half way through and waits for a second pass on a
compute node — a lot to set in motion because a registry returned `401` when
the real answer was `./build_containers.sh -L`. `nvloom` waits for `-S` for the
same reason even though it has no download path at all: it names what it wants
instead of committing you to a build.

One side effect worth knowing: a download-only run no longer needs write access
to the staging directory (`STAGE_DIR`, default
`/home/cmods/bringup/container-src`). Only `-S`/`-F` create it.

---

## Why local images

Jobs could name a registry URI directly — `docker://nvcr.io#nvidia/hpc-benchmarks:26.02`
— and enroot would pull it on first use. Three reasons we do not:

- **Every node pulls separately.** Enroot's pull cache is per node, so a
  first sweep across a rack is one full image download per node.
- **A registry outage stops testing.** Bringup often happens before the
  cluster has reliable external network, and the private NGC org behind the
  nvbandwidth image needs credentials distributed to every compute node.
- **One of the images cannot be pulled at all.** nvloom publishes only a
  sample Dockerfile. mnubergemm can be pulled, but only from the private org.

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
| nvbandwidth | `nvbandwidth-v0.9-<arch>.sqsh` | private NGC org pull; source build with `-S` | `nvbandwidth` |
| nvloom | `nvloom-v2.0.0-<arch>.sqsh` | built from the upstream sample Dockerfile | `nvloom` |
| mnubergemm | `mnubergemm-26.03-v1.17-<arch>.sqsh` | private NGC org, ARM only | `mnubergemm` |

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

Only reached when `-S` (or `-F`/`-B`, which imply it) asks for a source build —
see [Downloading vs building from source](#downloading-vs-building-from-source).

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

`mnubergemm` is unaffected — it is a registry import, so the headnode's own
architecture does not matter.

## Prerequisites

- `enroot` on the headnode, and on the compute nodes for the `-B` pass (pyxis
  already depends on it there, so this is a given).
- `squashfs-tools` for `unsquashfs` on the headnode — optional, see above.
- Write access to `/home/cmods/bringup/containers/` and `container-src/`.
- No docker, anywhere.
- An NGC API key if pulling from the private org, written to
  `~/.config/enroot/.credentials` by `./build_containers.sh -L` — see
  [Logging in to NGC](#logging-in-to-ngc). Needed on the machine doing the
  import only, never on a compute node.

## Options

```
-L            write the nvcr.io entry in ~/.config/enroot/.credentials, then exit
-S            allow the source-build fallback when a download fails
-A            every image the script knows about, ignoring CONTAINERS (implies -S)
-f            rebuild even if the .sqsh is already there
-l            list images and whether they are present, build nothing
-d DIR        write somewhere other than /home/cmods/bringup/containers
-a ARCH       build for arm or x86 rather than this machine
-F            fetch pass only (headnode); compile nothing   (implies -S)
-B            build pass only (compute node); fetch nothing (implies -S)
```

Options must come before image names — `getopts` stops at the first
non-option argument. With no image named and no `-A`, the list is `CONTAINERS`
from `SETTINGS`; see [Which images get built](#which-images-get-built).

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
references. A `401`/`403` there means no org access, or no credentials at all —
check [the login](#logging-in-to-ngc) first, since that is the usual cause. With
`-S` it then falls back to building v0.9 from the public source, a small CMake
project and a few minutes; without it the run stops there and says so.
The generated Dockerfile bases on `nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04`;
edit `NVBANDWIDTH_CUDA` in the script if the driver on the nodes is older, since
a CUDA base newer than the driver fails at run time, not at build time.

To enable the job, add `nvbandwidth` to `BENCHMARKS` in
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

To enable, add `nvloom` to `BENCHMARKS` in `SETTINGS`, and build the image with
`-S` — it is the one image with nothing to download. Scope 1
(basic health, ~10 min) is what runs by default; the Scope 2 burn-in `srun` is
present but commented, and needs `#SBATCH -t` raised above `BURN_IN_DURATION`
before use. nvloom is flagged *optional / exploratory* in the AI Factory Testing
Plan — Exhaustive only, not a required gate in any variant.

### mnubergemm

NVIDIA-internal and not buildable from anything we have, but it is published in
the same private NGC org as nvbandwidth, so `./build_containers.sh mnubergemm`
imports it like any other registry image — given credentials that can read org
`0948245400141054`, which is what `./build_containers.sh -L` sets up. `-S` does
not help here; there is no source to build.

Without those, the script prints the command and exits non-zero; obtain the
image through the internal channel for your platform and run it by hand:

```bash
enroot import -o /home/cmods/bringup/containers/mnubergemm-26.03-v1.17-arm.sqsh \
    docker://nvcr.io#0948245400141054/mnubergemm:tensorrt-26.03-v1.17-arm
```

The tag carries its own `-arm` suffix in addition to the `tensorrt-` prefix,
and only ARM is published today — an x86 build will fail the import rather than
silently produce the wrong image. Update `IMG` in `jobs/nvl72/mnubergemm.sbatch`
if the version or architecture suffix differs.

`mnubergemm` is not in `BENCHMARKS`. It is the burn-in phase — `BURNIN` in
`SETTINGS`, gated by `RUN_BURNIN`, which ships off — so the image is downloaded
by default but the job does not run until someone turns the phase on. That is
deliberate: flipping the switch at a site that never downloaded the image would
mean a fleet-wide failure on the first cycle instead of a burn-in.

Budget for a node being held for about three days once it is on: 12 runs of a
6:30:00 step, submitted one at a time, matching the plan's 24–72 hour row.
`MAX_JOB_HOURS` ships at `7` to clear a single run — see
[settings.md](settings.md#retry-and-drain-policy) for the full ladder of
limits, which have to move together if the workload's `--time_to_run` changes.

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

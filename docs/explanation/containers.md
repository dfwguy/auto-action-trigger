# Why the images are local, and how they get built

`build_containers.sh` builds the container images the jobs need as local `.sqsh`
files in `$CONTAINER_DIR`. `actions/file_copy.sh` rsyncs that
directory to `$NODE_CONTAINER_DIR` (`/opt/containers` by default) on each node,
and every job prefers the node-local copy. **Nothing is pulled from a registry
at job start.**

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
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?...}/$IMG
#CONT=docker://nvcr.io#nvidia/hpc-benchmarks:26.02
```

The `#` in that URI is enroot's separator between the registry host and the
image path — not a comment marker, and not something to normalise into a `/`.
Written `docker://nvcr.io/nvidia/hpc-benchmarks:26.02` the whole string is an
image path on the default registry, and the pull fails against Docker Hub rather
than against `nvcr.io`. It is the easiest part of the line to lose when copying
it out to run something by hand.

## What gets built is what you ask for

There is no list in `SETTINGS` of which images a site wants. There was, and
removing it is the point of this section.

`build_containers.sh` takes the images on its command line, or `-A` for all of
them. What it produces lands in `CONTAINER_DIR`, and `file_copy.sh` caches
**everything** in that directory on every node, with no opinion about which of
them matter. One place decides, once.

The alternative — a `CONTAINERS` key naming the wanted set, and the copy
filtering by it — looks tidier and is worse. It is a second place for the same
answer, so the two drift: a site that builds an image without adding it to the
list gets it on the share and never on a node, and the failure is a job reading
its image over NFS on every run, which is slow rather than broken and therefore
not noticed. Deciding at the point of building, and copying whatever resulted,
cannot drift because there is nothing to drift from.

The cost is that an image built and no longer used is copied to every node until
somebody deletes it from `CONTAINER_DIR`. That is a `rm` on one directory, and
it is visible — `build_containers.sh -l` lists what is there.

## A lock left by the old chain

`file_copy.sh` ran as root under BCM, so `/tmp/.file_copy.lock` on a node that
ever ran the old chain is root-owned. `/tmp` is sticky, so `$JOB_USER` can
neither write it nor remove it, and the copy stops there until the node reboots.

It says so, with the command:

```
EXIT: cannot open /tmp/.file_copy.lock as cmods -- owned by root. No copy was
      started. Fix: sudo rm -f /tmp/.file_copy.lock (on this node)
```

Fleet-wide:

```bash
clush -w '<nodes>' 'sudo rm -f /tmp/.file_copy.lock'
pdsh -R ssh -w '<nodes>' 'sudo rm -f /tmp/.file_copy.lock'
```

The failure used to escape to the journal instead, one line per node per cycle,
because `exec 9>"$lock" 2>/dev/null` opens its redirections **left to right**:
the open fails, and is reported, before stderr has been redirected anywhere.
`{ exec 9>"$lock"; } 2>/dev/null` is what suppresses it — the same trap
`launch_job.sh` documents on its trace writability check.

## The copy is its own unit

A first sync is several gigabytes. It cannot finish inside an agent cycle, so it
has to outlive one — and a background child of a `oneshot` unit does not.

The obvious shape, and the one this used for years, is `setsid nohup … &`:
detach, return, let the copy carry on. Under BCM that worked, because the action
was a plain process and nothing tidied up after it. Under systemd it does not.
`setsid` escapes the controlling terminal and the session; it does not escape
the **cgroup**, and `KillMode=control-group` — the default — SIGTERMs whatever
is left in the unit's cgroup the moment `ExecStart` returns.

So the copy got whatever was left of the cycle that started it, which is not a
duration anything chose. A cycle that runs the 45 health checks takes seconds; a
cycle with the health cadence closed and `RUN_JOBS=no` set exits every gate at
once and takes well under one. The same fleet showed both: nodes that filled
completely during their first cycles, and nodes stuck at exactly one image
because every cycle since had given the copy milliseconds. `--partial` meant
nothing was wasted, so it looked like slow progress rather than a fault — and
running `file_copy.sh` by hand always worked, which made the by-hand test
misleading rather than reassuring.

**The fix is not to make the cycle longer.** Depending on the parent to dawdle
is not a design, it is a race the copy usually loses, and it makes every other
step's runtime a hidden input to whether images arrive.

`systemd-run --user --collect --unit=bringup-copy` puts the copy in a transient
unit of its own. Its cgroup is not this cycle's, so nothing cleans it up when
the cycle ends; it runs to completion, once, however long that takes, and
`--collect` removes the unit when it finishes. A second cycle finding it already
running is refused by the unit name, which is the same answer the `flock` gives
and needs no coordination between them.

`systemctl --user status bringup-copy.service` and
`journalctl --user -u bringup-copy.service` are then the copy's own, which is a
better answer than the trace file for "what is it doing right now".

Two fallbacks, both deliberate. A hand-run from a plain shell with no user
manager has no cgroup to be cleaned out of, so `setsid` is enough there. With
neither available the copy runs inline and says so — it holds the cycle, which
is worse than detaching but better than not copying.

## How the caching works

Three layers, each avoiding a different transfer:

| Layer | Path | Populated by | Avoids |
|-------|------|--------------|--------|
| Build cache | `/tmp/enroot-cache/$UID`, docker's layer store | `build_containers.sh` | Re-pulling layers on rebuild |
| Shared copy | `CONTAINER_DIR` | `build_containers.sh` | Per-node registry pulls |
| Node-local cache | `NODE_CONTAINER_DIR` (`/opt/containers` default) | `actions/file_copy.sh` | Reading the image over NFS at every job start |

The last one is the one that matters at run time. A `.sqsh` is mounted, not
copied, so a job pointed at the NFS path streams the image over NFS for the
whole run — with several nodes starting the same benchmark at once, that is the
slowest part of a sweep. Each job resolves its image as:

```bash
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=${NODE_CONTAINER_DIR:-/opt/containers}/$IMG
[[ -f "$CONT" ]] || CONT=${CONTAINER_DIR:?...}/$IMG
```

so a node the rsync has not reached yet still runs, just off NFS.

`NODE_CONTAINER_DIR` defaults to `/opt/containers` rather than `/tmp` on
purpose: `/opt` survives a reboot, so a tray coming back does not have to refill
gigabytes of image over NFS before its first job can start off local disk again.
Moving it is one line in `SETTINGS`; a site with a bulk-storage mount for `/opt`
already, or one that would rather keep the old `/tmp`-and-reboot-clears-it
behaviour, sets it there instead. Whatever directory it names must exist and be
writable by `$JOB_USER` — `/tmp` was world-writable for free, `/opt` on a stock
image usually is not, and `file_copy.sh` traces `cannot create $dst` rather than
guess at a fallback if it is not.

`CONTAINER_DIR` and `NODE_CONTAINER_DIR` both arrive on `sbatch --export`,
because a batch script runs from Slurm's spool copy: it can neither read
`SETTINGS` nor work out where the tree is from its own path. `CONTAINER_DIR` is
`:?` rather than a default so that a job submitted without it stops and says so,
instead of falling back to a directory that a site which moved its images no
longer has; `NODE_CONTAINER_DIR` is `:-/opt/containers` because that default is
always a reasonable place to look, export or not. See
[sequencing.md#what-a-submission-carries](sequencing.md#what-a-submission-carries).

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
them as `$JOB_USER`.

`file_copy.sh` uses `rsync -a`, not `-r`. Without `-t` (implied by `-a`) the
destination mtimes are the copy time, the size+mtime quick check never matches,
and every agent cycle re-transfers the whole directory.

## One share, two mount points

`CONTAINER_DIR` is its own setting rather than `$BRINGUP_HOME/containers`
because the two directories have different shapes of problem. The tree is a few
megabytes of shell that has to be identical everywhere; the images are tens of
gigabytes that a site will want on whatever filesystem it bought for bulk data.
Deriving one from the other forced the images onto `/home`, and `/home` is
usually the smallest share a cluster has.

Having made it separate, a second problem follows: a bulk share is often not
mounted at the same path on the head node as on the compute nodes. `/data` on
the nodes can be `/mnt/server-1-data` on the head node, and nothing in the tree
can detect the difference — both paths exist, both are readable, and the only
symptom of using the wrong one is `build_containers.sh` writing images into a
directory the nodes never look in. That failure is silent for a whole sweep:
every job falls back to an NFS path that has no image, and the jobs fail one at
a time for what looks like an unrelated reason.

So each of the two shared directories has a pair of settings:

| Setting | Whose view | Read by |
|---------|-----------|---------|
| `CONTAINER_DIR` | the compute nodes | the `.sbatch` jobs, `actions/file_copy.sh`, `check_ib.sh` |
| `CONTAINER_DIR_HEAD` | the head node | `build_containers.sh`, `build_llmb.sh` |
| `CONTAINER_STAGE_DIR` | the compute nodes | `build_containers.sh -B`, which runs under `srun` |
| `CONTAINER_STAGE_DIR_HEAD` | the head node | `build_containers.sh -S`/`-F` |

Each `_HEAD` one defaults to the other, so a site with a single mount point
never has to know they exist. The split is by *which script* rather than by a
runtime test of which machine this is: every reader above is statically one or
the other, and `-B` — the one pass of `build_containers.sh` that runs on a node
rather than the head node — is told apart by the flag it was given, not guessed
at. A wrong guess here would put the images somewhere plausible and useless.

`NODE_CONTAINER_DIR` has no `_HEAD` pair: it names a path on the node's own
local disk, not a shared mount, so there is no second machine's view of it to
get wrong.

## Previewing a copy

Run the copy action in explain mode on a compute node to see the exact rsync
changes without creating the destination, taking a lock, starting a transient
service or writing a trace:

```bash
actions/file_copy.sh --explain
```

From the deployment root on the app server, group the answer across a node set:

```bash
clush -B -w '<nodes>' "$(pwd)/actions/file_copy.sh --explain"
pdsh -R ssh -w '<nodes>' "$(pwd)/actions/file_copy.sh --explain"
```

The itemized output covers everything under `CONTAINER_DIR`, not only `.sqsh`
files, because that is what the real `rsync -a --partial` invocation copies.
An empty itemized section followed by `up to date` means it would copy nothing.
`RUN_CONTAINER_COPY=no` stops real copies, not this read-only preview, so the
same command can inspect a whole paused fleet through `clush` or `pdsh`. The
preview prints a `NOTE` that a real run would start no copy, then continues with
the itemized changes that would be made if copying were enabled.

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
by hand from a shell on the node cannot catch it, because a fan-out — like any
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
to the staging directory (`CONTAINER_STAGE_DIR`). Only `-S`/`-F` create it.

## Matching the architecture

Every image filename in the tree carries an architecture suffix, and the jobs
build the whole name — `nvidia+hpc-benchmarks+26.02-arm.sqsh` — rather than
globbing for it. That is not decoration. An x86 image on an ARM node starts,
gets as far as `enroot-switchroot`, and dies:

```
enroot-switchroot: failed to execute: /bin/bash: Exec format error
error: pyxis: couldn't start container
```

Nothing in that names the architecture, and the job above it reports whatever
its gate says about an empty result file — a container problem arriving as a
benchmark failure.

The two LLM jobs are the exception and have to glob, because the same image
reaches a cluster under two names: `build_containers.sh` writes
`nvidia+nemo+<tag>-<arch>.sqsh` and the llmb installer writes
`nvidia+nemo+<tag>.sqsh` with no suffix. So they match the prefix and
**exclude the other architecture by name**.

Excluding is the operation, not preferring, and the reason is an ASCII
accident: `-` is `0x2D` and `.` is `0x2E`, so `nvidia+nemo+26.04.01-x86.sqsh`
sorts *before* `nvidia+nemo+26.04.01.sqsh`. A plain `ls | head -1` on a node
holding both picks the x86 one — which is how this was found.

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

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

`<arch>` is `arm` or `x86`, from `uname -m` on the machine that built the image.
This is a **CPU** architecture split, not a GPU-generation one: Grace and Vera
are `aarch64`, Intel and AMD hosts are `x86_64`. An image built on one does not
run on the other, so a mixed cluster needs a build on each — `build_containers.sh`
names the output after the machine it ran on, so both can live in the same
directory.

## Prerequisites

- `enroot` on the build machine (the headnode is fine).
- `docker` with `buildx`, for nvbandwidth's fallback path and for nvloom.
- Write access to `/home/cmods/bringup/containers/`.
- An NGC API key if pulling from the private org, in `ENROOT_CREDENTIALS`
  (`~/.config/enroot/.credentials`):
  `machine nvcr.io login $oauthtoken password <API_KEY>`.

## Options

```
-f            rebuild even if the .sqsh is already there
-l            list images and whether they are present, build nothing
-d DIR        write somewhere other than /home/cmods/bringup/containers
```

Environment: `CONTAINER_DIR` (same as `-d`), `WORKDIR` (source checkouts,
default `/tmp/container-build-$UID`), `ENROOT_CACHE_PATH`, `ENROOT_TEMP_PATH`.

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

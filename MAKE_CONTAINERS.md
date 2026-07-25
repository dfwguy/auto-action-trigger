# Building containers for the optional jobs

Most jobs in `jobs/` need nothing built on our side — they either run a
host-installed binary (`dcgm*`, `nvsm`, `stress-ng`, `memtester`,
`stressapptest`, `fio`, `ethr`) or pull a public upstream image at job start:

```
docker://nvcr.io#nvidia/hpc-benchmarks:26.02
```

That image is on the public NGC catalog and covers `allreduce`, `alltoall`,
both `-nonvlink` variants, `hpl`, `cublasmatmul`, and `stream`. Enroot pulls it
on first use and caches it — no import step, no `.sqsh` to distribute. Note the
enroot `#` separator between the registry host and the image path; a `/` there
will fail to resolve.

Three jobs have **no public upstream image** and are therefore left out of the
`benchmarks=` list in `actions/launch_job.sh`. Each needs an image built or
imported once, published to `/home/cmods/bringup/containers/`, and then added
to that list. This file covers those three.

| Job | Why it needs work | Section |
|-----|-------------------|---------|
| `nvbandwidth` | Image lives in a private NGC org; no public build | [nvbandwidth](#nvbandwidth) |
| `nvloom` | Upstream publishes a sample Dockerfile only | [nvloom](#nvloom) |
| `mnubergemm` | NVIDIA-internal build, not publicly distributed | [mnubergemm](#mnubergemm) |

---

## Prerequisites

- `enroot` on the machine doing the import (the headnode is fine).
- An NGC API key if pulling from a private org: `enroot import` reads
  `ENROOT_CREDENTIALS` (`~/.config/enroot/.credentials`), formatted as
  `machine nvcr.io login $oauthtoken password <API_KEY>`.
- Write access to `/home/cmods/bringup/containers/`. `actions/file_copy.sh`
  rsyncs that directory to `/tmp/containers/` on each node.
- Build images on the **same CPU architecture** as the target nodes, or use
  `docker buildx --platform`. Grace and Vera are ARM (`aarch64`); Intel and AMD
  hosts are `x86_64`. This is a CPU-architecture split, not a GPU-generation
  one.

---

## nvbandwidth

Upstream: [github.com/NVIDIA/nvbandwidth](https://github.com/NVIDIA/nvbandwidth)
(v0.9). NVIDIA publishes no container on the public NGC catalog — the source
repo ships build instructions only.

### Option A — import the NGC org image (fastest, needs org access)

`incubation/nvbandwidth-single-node-mop.md` in the validation-mops repo
references prebuilt images in a private NGC org:

```bash
# ARM (Grace, Vera)
enroot import -o /home/cmods/bringup/containers/nvbandwidth-arm.sqsh \
    docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-arm

# x86 (Intel, AMD)
enroot import -o /home/cmods/bringup/containers/nvbandwidth-x86.sqsh \
    docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-x86
```

This needs an NGC API key with access to org `0948245400141054`. If the pull
returns `401`/`403`, you do not have access — use Option B.

`jobs/nvbandwidth.sbatch` defaults to the registry URI directly, so if enroot
on the compute nodes has those credentials, no import is needed at all. Swap to
the commented `.sqsh` block in that file if you prefer a local import.

### Option B — build from source

```bash
git clone https://github.com/NVIDIA/nvbandwidth.git
cd nvbandwidth
cat > Dockerfile <<'EOF'
FROM nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake build-essential libboost-program-options-dev && \
    rm -rf /var/lib/apt/lists/*
COPY . /src
WORKDIR /src
RUN cmake -B build && cmake --build build -j && \
    install -m 0755 build/nvbandwidth /usr/local/bin/nvbandwidth
WORKDIR /
EOF
docker buildx build . -t nvbandwidth:v0.9
docker save nvbandwidth:v0.9 -o nvbandwidth.tar
enroot import -o /home/cmods/bringup/containers/nvbandwidth-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh \
    dockerd://nvbandwidth:v0.9
```

Match the CUDA base image to the driver on the nodes.

### Enable

Uncomment the `.sqsh` block in `jobs/nvbandwidth.sbatch` if you imported
locally, then add `nvbandwidth` to `benchmarks=` in `actions/launch_job.sh`.

The job's parse section enforces only the platform-independent criteria from
MOP §6.2 (coefficient of variation > 0.02, `N/A` peer transfers, tool errors).
The per-test `SUM` thresholds in §6.1 are the GB200 4-GPU baseline — add a
per-platform table before relying on them.

---

## nvloom

Upstream: [github.com/NVIDIA/nvloom](https://github.com/NVIDIA/nvloom). The repo
provides a sample `Dockerfile` and states outright that it is only a sample you
will want to customize. No image is published to any registry.

```bash
git clone https://github.com/NVIDIA/nvloom.git
cd nvloom
docker buildx build . -t nvloom:v2.0.0
docker save nvloom:v2.0.0 -o nvloom.tar
enroot import -o /home/cmods/bringup/containers/nvidian+nvis+nvloom+v2.0.0-arm.sqsh \
    dockerd://nvloom:v2.0.0
```

The filename above matches the reference image in `incubation/nvloom_MOP.md`;
rename to taste and update `CONT` in `jobs/nvloom.sbatch` to match.

`nvloom_cli` runs under MPI with one process per GPU. The job script already
sets `NVIDIA_VISIBLE_DEVICES=all` for the Pyxis GPU hook and deliberately omits
`--gpus-per-task` — nvloom assigns GPUs by MPI local rank, and scoping CUDA
devices per task causes `CUDA_ERROR_NO_DEVICE`.

Node-side prerequisite is IMEX, not fabricmanager: `/dev/nvidia-caps-imex-channels/`
must be populated and the IMEX service healthy. On NVL72 the NVLink domain is
managed by NMX-C on the switch trays and the hosts run `nvidia-imex`;
`node_health.sh` already covers those checks.

### Enable

Add `nvloom` to `benchmarks=` in `actions/launch_job.sh`. Scope 1 (basic health,
~10 min) is what runs by default; the Scope 2 burn-in `srun` is present but
commented, and needs `#SBATCH -t` raised above `BURN_IN_DURATION` before use.

nvloom is flagged *optional / exploratory* in the AI Factory Testing Plan —
Exhaustive only, and not a required gate in any variant.

---

## mnubergemm

NVIDIA-internal, not publicly distributed. `jobs/mnubergemm.sbatch` expects:

```
/home/cmods/bringup/containers/mnubergemm-26.03-v1.17-arm.sqsh
```

Obtain the image through the internal channel for your platform, import it with
`enroot import`, and update `CONT` in the job to the resulting filename. The
version and architecture suffix must match the nodes under test.

Burn-in runs 24–72 hours per the plan, so it is not a candidate for the default
sequence — `MAX_JOB_HOURS` in `actions/launch_job.sh` defaults to 6 and will
drain the node with a timeout reason well before a real burn-in finishes. Raise
it before enabling.

---

## Verifying an image before enabling a job

```bash
srun --nodes=1 --nodelist=<node> --exclusive --gpus-per-node=4 \
     --container-image=<uri-or-sqsh> \
     <binary> --help
```

If that resolves and runs, the job will too. Check `results/<node>/<job>.txt`
after the first real run — the last line is `DONE` or `FAIL`, and the sequencer
drains the node on `FAIL`.

# Build the container images

Run on the headnode, once per CPU architecture in the cluster.

```bash
./build_containers.sh -L                  # log in to nvcr.io, once per machine
./build_containers.sh -a arm hpc-benchmarks nvbandwidth mnubergemm   # these, whatever is missing
./build_containers.sh -l                  # files actually present, and the login state
./build_containers.sh -a arm -l           # expected ARM images: present, missing, or staged
```

Downloading is the normal path and, by default, the only one. Everything the
script knows about except `nvloom` is published on `nvcr.io`; compiling from
source is a fallback that happens only when `-S` asks for it.

## Options

```
-L            write the nvcr.io entry in ~/.config/enroot/.credentials, then exit
-S            allow the source-build fallback when a download fails
-A            every image the script knows about (implies -S)
-f            rebuild even if the .sqsh is already there
-l            list images and whether they are present, build nothing
-d DIR        write somewhere other than /cluster/bringup-data/containers
-a ARCH       arm or x86 -- required for everything except -L and -h
--no-login    build nvbandwidth or mnubergemm without checking nvcr.io login first
-F            fetch pass only (headnode); compile nothing   (implies -S)
-B            build pass only (compute node); fetch nothing (implies -S)
```

Options must come before image names — `getopts` stops at the first non-option
argument. **Naming the images is required**: with none named and no `-A` the
script prints the known list and exits, rather than guessing from a setting.
See [explanation/containers.md#what-gets-built-is-what-you-ask-for](../explanation/containers.md#what-gets-built-is-what-you-ask-for).

**`-a` is required**, for everything that touches an image — the headnode's
own architecture is not assumed, because it is frequently wrong: this
framework's headnode is commonly x86 while the trays it is building for are
ARM. `-L` (writes one file, builds nothing) and `-h` are the only exceptions.
`$ARCH` works the same as `-a` for a run where passing the flag every time is
inconvenient. See
[Building ARM images on an x86 headnode](#building-arm-images-on-an-x86-headnode).

`CONTAINER_DIR` and `CONTAINER_STAGE_DIR` are `SETTINGS` keys, not just
environment overrides, and each has a `_HEAD` pair for a share the head node
mounts elsewhere — see
[explanation/containers.md#one-share-two-mount-points](../explanation/containers.md#one-share-two-mount-points).
`-d` overrides the destination for one run.

Environment: `ARCH` (same as `-a`), `WORKDIR`
(scratch, default `/tmp/container-build-$UID`), `ENROOT_CACHE_PATH`,
`ENROOT_TEMP_PATH`, `ENROOT_DATA_PATH`, `ENROOT_RUNTIME_PATH`.

```bash
./build_containers.sh -a arm nvloom   # just this one
./build_containers.sh -a arm -A       # every image the script knows about
```

`-A` includes `nvloom`, which no registry publishes at all — so it implies `-S`
and compiles it, which is a much longer run than the downloads.

## Prerequisites

- `enroot` on the headnode, and on the compute nodes for the `-B` pass (pyxis
  already depends on it there, so this is a given).
- `squashfs-tools` for `unsquashfs` on the headnode — optional.
- Write access to `/cluster/bringup-data/containers/` and `container-src/`.
- No docker, anywhere.
- An NGC API key if pulling from the private org — see below. Needed on the
  machine doing the import only, **never** on a compute node.

## Logging in to NGC

`hpc-benchmarks` and the CUDA base images are public. `nvbandwidth` and
`mnubergemm` live in private NGC org `0948245400141054`, and a request for
either refuses before doing anything if `~/.config/enroot/.credentials` has no
`nvcr.io` entry — one line naming the fix, rather than a network round trip
that ends in a `401`/`403` enroot reports as a plain import failure. `--no-login`
skips this check and attempts the import anyway, which still ends in that same
`401`/`403` without real credentials; it exists for whatever reason a site
keeps credentials somewhere this check does not look.

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
is why the file has to be written with a **quoted** heredoc if you do it by
hand:

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
in to is `0948245400141054`; **a valid key for the wrong org fails exactly like
no key at all.**

What `-L` does beyond the heredoc above:

- It replaces only the `nvcr.io` entry and keeps any others, so a site with a
  private mirror in the same file does not lose it.
- It writes through a `umask 077` temp file, so the key is never briefly world
  readable. `read -rs` keeps it out of terminal scrollback, and passing it in
  `NGC_API_KEY` keeps it out of shell history.
- It does **not** verify the key — nothing short of an import can. The next
  import is the check, which is why it suggests one.

`ENROOT_CONFIG_PATH` (or `XDG_CONFIG_HOME`) moves the file; the script follows
both. Images reach the nodes as `.sqsh` files over NFS, so no credential is ever
distributed to a compute node.

## Building ARM images on an x86 headnode

`-a` (or `$ARCH`) is required, not just recommended — the script refuses to
guess from `uname -m` on whatever machine is running it, since the headnode's
own architecture is frequently not the trays':

```bash
./build_containers.sh -a arm            # or ARCH=arm ./build_containers.sh
```

Registry pulls cross-build for free and finish on the headnode. Source builds —
`nvloom`, and `nvbandwidth`'s fallback — need two passes, because the only ARM
machines are the compute nodes. `-a` is required on **both** passes, including
the `-B` one run on the ARM node itself:

```bash
./build_containers.sh -a arm -F nvloom         # headnode: fetch, compile nothing
srun -N1 ./build_containers.sh -a arm -B nvloom  # ARM node: compile, produce the .sqsh
```

Why it is split this way is
[explanation/containers.md#the-two-pass-source-build](../explanation/containers.md#the-two-pass-source-build).

## Per-image notes

### hpc-benchmarks

Public NGC catalog image, no credentials needed. Six jobs use it, so it is the
one with the most to gain from a single local copy.

### nvbandwidth

Upstream: [github.com/NVIDIA/nvbandwidth](https://github.com/NVIDIA/nvbandwidth)
(v0.9). No image on the public catalog.

The script first tries the prebuilt image in NGC org `0948245400141054`. A
`401`/`403` there means no org access, or no credentials at all — check the
login first, since that is the usual cause. With `-S` it then falls back to
building v0.9 from the public source, a small CMake project and a few minutes.

The generated Dockerfile bases on
`nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04`; edit `NVBANDWIDTH_CUDA` in the
script if the driver on the nodes is older, since **a CUDA base newer than the
driver fails at run time, not at build time.**

The job's parse section enforces only the platform-independent criteria from MOP
§6.2 (coefficient of variation > 0.08, `N/A` peer transfers, tool errors). The
per-test `SUM` thresholds in §6.1 are the GB200 4-GPU baseline — add a
per-platform table before relying on them.

### nvloom

Upstream: [github.com/NVIDIA/nvloom](https://github.com/NVIDIA/nvloom). The repo
provides a `Dockerfile` and states outright that it is a sample you will want to
customize — it builds and runs as-is, but read it before trusting it on a new
platform. No image is published anywhere, so this is the one image that needs
`-S`.

The node-side prerequisite is IMEX, not fabricmanager:
`/dev/nvidia-caps-imex-channels/` must be populated and the IMEX service
healthy. On NVL72 the NVLink domain is managed by NMX-C on the switch trays and
the hosts run `nvidia-imex`; `node_health.sh` already covers those checks.

Scope 1 (basic health, ~10 min) is what runs by default; the Scope 2 burn-in
`srun` is present but commented, and needs `#SBATCH -t` raised above
`BURN_IN_DURATION` before use.

### mnubergemm

NVIDIA-internal and not buildable from anything we have, but it is published in
the same private NGC org as nvbandwidth, so `./build_containers.sh -a arm mnubergemm`
imports it like any other registry image. `-S` does not help here; there is no
source to build.

Without credentials, the script prints the command and exits non-zero; obtain
the image through the internal channel for your platform and run it by hand:

```bash
enroot import -o /cluster/bringup-data/containers/mnubergemm-26.03-v1.17-arm.sqsh \
    docker://nvcr.io#0948245400141054/mnubergemm:tensorrt-26.03-v1.17-arm
```

The tag carries its own `-arm` suffix in addition to the `tensorrt-` prefix, and
only ARM is published today — an x86 build will fail the import rather than
silently produce the wrong image. Update `IMG` in
`jobs/nvl72/mnubergemm.sbatch` if the version or architecture suffix differs.

`mnubergemm` is downloaded by default but its job does not run until
`RUN_BURNIN` is turned on. See
[enable-a-benchmark.md#turn-burn-in-on](enable-a-benchmark.md#turn-burn-in-on).

### pytorch

Public NGC catalog image, no credentials needed, imported like `hpc-benchmarks`;
name the architecture the same way. It carries `nccl-tests` and a newer NCCL than
`hpc-benchmarks` does, and is what the `-pytorch` NCCL jobs run. It sits beside
`hpc-benchmarks` rather than replacing it, which `hpl`, `cublasmatmul` and
`stream` still need.

```bash
./build_containers.sh -a x86 pytorch
```

`PYTORCH_TAG` is the release (`26.08`); the script appends `-py3` for the
registry tag, so the file is `nvidia+pytorch+26.08-<arch>.sqsh`.

### nemo

Public NGC catalog image, imported like `hpc-benchmarks`. **Name the
architecture** — the compute nodes are ARM and the head node may not be:

```bash
./build_containers.sh -a arm nemo
```

A registry pull cross-builds for free, so this finishes on the head node. Get it
wrong and the job fails at container start with `Exec format error`, which names
nothing useful — see
[explanation/containers.md#matching-the-architecture](../explanation/containers.md#matching-the-architecture).

It is the image both LLM jobs run, and it is large — budget tens of gigabytes.
The tag is pinned in `build_containers.sh` as `NEMO_TAG` and **must match the
recipe the jobs were captured against**; the framework version is the only thing
tying a step time to a recipe now that `llmb-run` is not in the launch path. See
[explanation/llmb.md#the-frozen-recipe](../explanation/llmb.md#the-frozen-recipe).

The llmb installer imports the same image into `$LLMB_INSTALL/images/`. If you
already have an install, copying it across is faster than importing it twice:

```bash
cp "$LLMB_INSTALL"/images/nvidia+nemo+*.sqsh "$CONTAINER_DIR"/
```

Either way the jobs find it by the glob `nvidia+nemo+*.sqsh`, so the installer's
name and this script's `-${arch}` suffixed one both work. The recipe script
comes from `/opt/Megatron-Bridge` in the image and the cache comes from
`LLM_HF_HOME`; neither job reads `$LLMB_INSTALL`. See
[capture-an-sbatch-from-llmb-run.md#getting-the-image-onto-the-nodes](capture-an-sbatch-from-llmb-run.md#getting-the-image-onto-the-nodes).

## Verify an image before enabling its job

```bash
srun --nodes=1 --nodelist=<node> --exclusive --gpus-per-node=4 \
     --container-image=${NODE_CONTAINER_DIR:-/opt/containers}/<file>.sqsh \
     <binary> --help
```

If that resolves and runs, the job will too. If `NODE_CONTAINER_DIR` is empty on
the node, the rsync has not run yet — `actions/file_copy.sh` runs on every agent
cycle, or run it by hand.

Check `results/<node>/<job>.txt` after the first real run — the last line is
`DONE` or `FAIL`.

#!/bin/bash
#
# Build the container images the benchmark jobs run from, as local .sqsh files
# in /home/cmods/bringup/containers/.
#
# Nothing here is required for the jobs to *work* -- most of them can pull
# straight from nvcr.io. It exists so that the images are pulled once, on one
# machine, instead of once per node on first use, and so the jobs keep running
# when the registry or the NGC credentials are unavailable.
#
# actions/file_copy.sh rsyncs the output directory to /tmp/containers/ on each
# node, and every job prefers that node-local copy over the NFS one. See
# BUILD_CONTAINERS.md.
#
#   ./build_containers.sh                 # everything that is missing
#   ./build_containers.sh hpc-benchmarks  # just one image
#   ./build_containers.sh -f nvloom       # rebuild even if the .sqsh exists
#   ./build_containers.sh -l              # list images and their status
#
set -u

DEST=${CONTAINER_DIR:-/home/cmods/bringup/containers}
FORCE=0
LIST=0

## Architecture suffix. This is a CPU split, not a GPU-generation one: Grace
## and Vera are ARM, Intel and AMD hosts are x86. Images built here only run on
## nodes of the same architecture as this machine.
arch=$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/')

## Layer cache and scratch space for enroot and docker. Both default to
## locations under $HOME, which on this cluster is NFS -- every import would
## write a multi-gigabyte layer tree over the wire and then read it back.
## Keeping them on local disk is the whole point of the exercise.
export ENROOT_CACHE_PATH=${ENROOT_CACHE_PATH:-/tmp/enroot-cache/$UID}
export ENROOT_TEMP_PATH=${ENROOT_TEMP_PATH:-/tmp/enroot-temp/$UID}
WORKDIR=${WORKDIR:-/tmp/container-build-$UID}

HPC_BENCHMARKS_TAG=26.02
NVBANDWIDTH_VERSION=v0.9
NVBANDWIDTH_ORG=0948245400141054
NVBANDWIDTH_CUDA=nvcr.io/nvidia/cuda:13.0.1-devel-ubuntu24.04
NVLOOM_VERSION=v2.0.0
MNUBERGEMM_IMAGE=mnubergemm-26.03-v1.17-arm.sqsh

usage() {
    awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    echo
    echo "Images: hpc-benchmarks nvbandwidth nvloom mnubergemm"
    exit "${1:-0}"
}

log()  { printf '\n== %s\n' "$*"; }
warn() { printf 'build_containers: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

## Name of the .sqsh each image lands as. Job scripts build the same string, so
## a rename here needs the matching edit in jobs/.
image_file() {
    case "$1" in
        hpc-benchmarks) echo "nvidia+hpc-benchmarks+${HPC_BENCHMARKS_TAG}-${arch}.sqsh" ;;
        nvbandwidth)    echo "nvbandwidth-${NVBANDWIDTH_VERSION}-${arch}.sqsh" ;;
        nvloom)         echo "nvloom-${NVLOOM_VERSION}-${arch}.sqsh" ;;
        mnubergemm)     echo "$MNUBERGEMM_IMAGE" ;;
        *)              return 1 ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

## Import into a temp name and move into place only on success, so an
## interrupted or failed import never leaves a truncated .sqsh that the jobs
## would then happily try to mount.
import() {
    local out="$1" uri="$2" tmp
    tmp="$DEST/.$(basename "$out").$$"
    if enroot import -o "$tmp" "$uri"; then
        mv -f "$tmp" "$out"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

## Clone at a tag, or refresh an existing clone. Keeps repeat runs offline-ish
## and avoids a fresh multi-hundred-MB clone every time.
fetch_repo() {
    local url="$1" dir="$2" ref="$3"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" fetch --tags --quiet origin || warn "fetch failed, using existing checkout of $dir"
    else
        git clone --quiet "$url" "$dir" || return 1
    fi
    git -C "$dir" checkout --quiet "$ref" 2>/dev/null ||
        warn "$(basename "$dir"): ref $ref not found, staying on the default branch"
}

## ── hpc-benchmarks ────────────────────────────────────────────────────────
## Public NGC image, no credentials needed. Covers allreduce, alltoall, both
## -nonvlink variants, hpl, cublasmatmul, and stream -- six of the jobs, so
## this is the one with the most to gain from a local copy.
build_hpc_benchmarks() {
    local out="$1"
    log "hpc-benchmarks: importing nvcr.io#nvidia/hpc-benchmarks:${HPC_BENCHMARKS_TAG} ($arch)"
    import "$out" "docker://nvcr.io#nvidia/hpc-benchmarks:${HPC_BENCHMARKS_TAG}"
}

## ── nvbandwidth ───────────────────────────────────────────────────────────
## Prebuilt images exist in a private NGC org. If we can read it, that is a
## straight import; otherwise fall back to building v0.9 from the public source
## repo, which is a small CMake project and takes a few minutes.
build_nvbandwidth() {
    local out="$1" uri="docker://nvcr.io#${NVBANDWIDTH_ORG}/nvbandwidth-single-node:${NVBANDWIDTH_VERSION}-${arch}"

    log "nvbandwidth: trying the NGC org image"
    if import "$out" "$uri"; then
        return 0
    fi
    warn "nvbandwidth: NGC org import failed (no access to org ${NVBANDWIDTH_ORG}?) -- building from source"

    have docker || die "nvbandwidth: source build needs docker"
    local src="$WORKDIR/nvbandwidth"
    fetch_repo https://github.com/NVIDIA/nvbandwidth.git "$src" "$NVBANDWIDTH_VERSION" || return 1

    ## Upstream ships build instructions but no Dockerfile. Match the CUDA base
    ## to the driver on the nodes -- a base newer than the driver fails at run
    ## time, not here.
    cat > "$src/Dockerfile.bringup" <<EOF
FROM ${NVBANDWIDTH_CUDA}
RUN apt-get update && apt-get install -y --no-install-recommends \\
        cmake build-essential libboost-program-options-dev && \\
    rm -rf /var/lib/apt/lists/*
COPY . /src
WORKDIR /src
RUN cmake -B build && cmake --build build -j && \\
    install -m 0755 build/nvbandwidth /usr/local/bin/nvbandwidth
WORKDIR /
EOF
    docker buildx build "$src" -f "$src/Dockerfile.bringup" \
        -t "nvbandwidth:${NVBANDWIDTH_VERSION}" --load || return 1
    import "$out" "dockerd://nvbandwidth:${NVBANDWIDTH_VERSION}"
}

## ── nvloom ────────────────────────────────────────────────────────────────
## No image published anywhere. The repo carries a Dockerfile it describes as a
## sample -- it builds and runs as-is, but read it before trusting it on a new
## platform.
build_nvloom() {
    local out="$1" src="$WORKDIR/nvloom"

    have docker || die "nvloom: needs docker"
    log "nvloom: building ${NVLOOM_VERSION} from source"
    fetch_repo https://github.com/NVIDIA/nvloom.git "$src" "$NVLOOM_VERSION" || return 1
    [[ -f "$src/Dockerfile" ]] || die "nvloom: no Dockerfile in the checkout"

    docker buildx build "$src" -t "nvloom:${NVLOOM_VERSION}" --load || return 1
    import "$out" "dockerd://nvloom:${NVLOOM_VERSION}"
}

## ── mnubergemm ────────────────────────────────────────────────────────────
## NVIDIA-internal, not distributed publicly and not buildable from anything we
## have. Nothing to do but say so.
build_mnubergemm() {
    local out="$1"
    warn "mnubergemm is NVIDIA-internal -- there is no public source or registry to build from."
    warn "Obtain the image through the internal channel for your platform and import it:"
    warn "    enroot import -o $out dockerd://<image>:<tag>"
    warn "The version and -arch suffix must match the nodes under test."
    return 1
}

while getopts ':fld:h' opt; do
    case "$opt" in
        f) FORCE=1 ;;
        l) LIST=1 ;;
        d) DEST="$OPTARG" ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

images=("$@")
[[ "${#images[@]}" -eq 0 ]] && images=(hpc-benchmarks nvbandwidth nvloom mnubergemm)

for img in "${images[@]}"; do
    image_file "$img" >/dev/null || die "unknown image: $img"
done

if [[ "$LIST" -eq 1 ]]; then
    printf '%-16s %-52s %s\n' IMAGE FILE STATUS
    for img in "${images[@]}"; do
        f=$(image_file "$img")
        if [[ -f "$DEST/$f" ]]; then
            status="present ($(du -h "$DEST/$f" | cut -f1))"
        else
            status=missing
        fi
        printf '%-16s %-52s %s\n' "$img" "$f" "$status"
    done
    exit 0
fi

have enroot || die "enroot is not installed -- run this on the headnode"
mkdir -p "$DEST" "$WORKDIR" "$ENROOT_CACHE_PATH" "$ENROOT_TEMP_PATH" ||
    die "cannot create $DEST -- check write access"

failed=()
for img in "${images[@]}"; do
    out="$DEST/$(image_file "$img")"

    if [[ -f "$out" && "$FORCE" -eq 0 ]]; then
        echo "$img: $(basename "$out") already present, skipping (-f to rebuild)"
        continue
    fi

    if "build_${img//-/_}" "$out"; then
        echo "$img: $out"
    else
        failed+=("$img")
    fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
    warn "did not build: ${failed[*]}"
    exit 1
fi

log "done -- $DEST"
ls -lh "$DEST"/*.sqsh 2>/dev/null

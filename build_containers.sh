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
# Two of the images have no published build and are compiled from source. Only
# the headnode has internet and only the compute nodes are ARM, so those two
# are done in two passes: -F fetches everything on the headnode, -B compiles it
# natively on a node. Registry pulls need only the -F pass.
#
#   ./build_containers.sh                    # everything that is missing
#   ./build_containers.sh hpc-benchmarks     # just one image
#   ./build_containers.sh -f nvloom          # rebuild even if the .sqsh exists
#   ./build_containers.sh -l                 # list images and their status
#   ./build_containers.sh -a arm -F          # headnode: fetch ARM sources
#   srun -N1 ./build_containers.sh -B        # ARM node: compile what was fetched
#
set -u

DEST=${CONTAINER_DIR:-/home/cmods/bringup/containers}
STAGE=${STAGE_DIR:-/home/cmods/bringup/container-src}
FORCE=0
LIST=0
MODE=all

## Architecture suffix. This is a CPU split, not a GPU-generation one: Grace
## and Vera are ARM, Intel and AMD hosts are x86.
##
## Defaults to this machine, but -a/$ARCH overrides it, because the headnode is
## x86 and the nodes are ARM. Cross-architecture is fine for everything the
## fetch pass does -- an import downloads layers, untars them and runs
## mksquashfs, and a package download is just a download. Nothing from inside
## the image is ever executed until the build pass, which runs on the target.
arch=${ARCH:-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/')}

## Layer cache and scratch space for enroot. Both default to locations under
## $HOME, which on this cluster is NFS -- every import would write a
## multi-gigabyte layer tree over the wire and then read it back. Keeping them
## on local disk is the whole point of the exercise.
export ENROOT_CACHE_PATH=${ENROOT_CACHE_PATH:-/tmp/enroot-cache/$UID}
export ENROOT_TEMP_PATH=${ENROOT_TEMP_PATH:-/tmp/enroot-temp/$UID}

## enroot creates these two at startup for every subcommand, import included.
## The compute nodes get them from /etc/enroot/enroot.conf; the headnode does
## not, and the compiled defaults (/var/lib/enroot, /run/enroot) are root-only.
## Unprivileged paths here -- building as root would leave root-owned .sqsh
## files for file_copy.sh and the jobs to trip over.
export ENROOT_DATA_PATH=${ENROOT_DATA_PATH:-/tmp/enroot-data/$UID}
export ENROOT_RUNTIME_PATH=${ENROOT_RUNTIME_PATH:-/tmp/enroot-runtime/$UID}
WORKDIR=${WORKDIR:-/tmp/container-build-$UID}

HPC_BENCHMARKS_TAG=26.02
NVBANDWIDTH_VERSION=v0.9
NVBANDWIDTH_ORG=0948245400141054
NVLOOM_VERSION=v2.0.0
MNUBERGEMM_IMAGE=mnubergemm-26.03-v1.17-arm.sqsh

## Ubuntu release the CUDA base images are built on, and the mirrors the
## packages come from. Ubuntu serves ARM from a different host than x86.
UBUNTU_SUITE=noble
UBUNTU_MIRROR_amd64=http://archive.ubuntu.com/ubuntu
UBUNTU_MIRROR_arm64=http://ports.ubuntu.com/ubuntu-ports

## Native-architecture throwaway image used on the headnode to run apt. It is
## never shipped anywhere -- it exists only because resolving and downloading
## ARM packages needs a working apt, and the host's apt is configured for the
## host's release.
HELPER_URI=docker://ubuntu:24.04

usage() {
    awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
    echo
    echo "Images: hpc-benchmarks nvbandwidth nvloom mnubergemm"
    echo "Arch:   arm x86 (default: this machine; \$ARCH also works)"
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

## Two different spellings of the same thing, and they are not interchangeable.
##
## enroot's --arch takes the kernel's name and runs it through its own
## debarch() before matching .platform.architecture in the registry manifest
## list -- so it wants aarch64, and handing it arm64 fails with "Unsupported
## architecture". apt, on the other hand, wants the Debian name.
enroot_arch() { case "$1" in arm) echo aarch64 ;; x86) echo x86_64 ;; esac; }
deb_arch()    { case "$1" in arm) echo arm64   ;; x86) echo amd64   ;; esac; }

## Import into a temp name and move into place only on success, so an
## interrupted or failed import never leaves a truncated .sqsh that the jobs
## would then happily try to mount.
import() {
    local out="$1" uri="$2" tmp
    tmp="$(dirname "$out")/.$(basename "$out").$$"
    if enroot import -a "$(enroot_arch "$arch")" -o "$tmp" "$uri" &&
       mv -f "$tmp" "$out"; then
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

## ── source-built image definitions ────────────────────────────────────────
## The two images with no published build. Each sets the base image, the
## upstream repo, the apt packages the build needs, and the commands that turn
## a checkout into an installed binary. The commands run inside the base
## container on a node of the target architecture, never here.
##
## The base tags track what upstream builds against -- nvloom's own Dockerfile
## pins CUDA 13.1.0. A base newer than the driver on the nodes fails at run
## time, not at build time, so check both when bumping.
spec() {
    case "$1" in
    nvbandwidth)
        BASE_URI="docker://nvcr.io#nvidia/cuda:13.0.1-devel-ubuntu24.04"
        REPO=https://github.com/NVIDIA/nvbandwidth.git
        REF=$NVBANDWIDTH_VERSION
        PKGS="cmake build-essential libboost-program-options-dev"
        BUILD_CMDS='cmake -B build && cmake --build build -j"$(nproc)" &&
                    install -m 0755 build/nvbandwidth /usr/local/bin/nvbandwidth'
        ;;
    nvloom)
        ## Packages and build steps both come from the sample Dockerfile in the
        ## upstream repo. We keep everything in the devel image rather than
        ## copying the binary into a slim runtime stage the way upstream does;
        ## see BUILD_CONTAINERS.md on the size trade.
        BASE_URI="docker://nvcr.io#nvidia/cuda:13.1.0-devel-ubuntu24.04"
        REPO=https://github.com/NVIDIA/nvloom.git
        REF=$NVLOOM_VERSION
        PKGS="cmake libopenmpi-dev libopenmpi3t64 libboost-program-options-dev"
        BUILD_CMDS='cmake . && make -j"$(nproc)" &&
                    install -m 755 nvloom_cli /usr/local/bin/ &&
                    install -m 755 cli/plot_heatmaps.py /usr/local/bin/'
        ;;
    *)  return 1 ;;
    esac
}

from_source() { spec "$1" >/dev/null 2>&1; }

## ── fetch pass (headnode) ─────────────────────────────────────────────────

## Pull the target architecture's packages into a directory that apt on the
## node can use as a repository. Two problems to get around: this machine is
## the wrong architecture, and its apt is configured for its own release.
##
## Both go away by running apt inside a throwaway native container with a
## private state directory and APT::Architecture forced to the target. Because
## the target is "native" as far as that apt is concerned, the resolver never
## hits the co-installability rules that make foreign-arch downloads fail. And
## because resolving and downloading never executes any of the packages, none
## of this needs emulation.
fetch_debs() {
    local dir="$1" pkgs="$2" base="$3" dpkg_arch mirror status_src
    dpkg_arch=$(deb_arch "$arch")
    mirror="UBUNTU_MIRROR_${dpkg_arch}"; mirror="${!mirror}"

    ## Seed apt's status file from the base image so it downloads only what the
    ## image is actually missing. unsquashfs reads a single path out of the
    ## .sqsh without mounting it, so this stays unprivileged. Without it apt
    ## thinks nothing is installed and pulls the entire dependency closure --
    ## still correct, just a much larger download.
    status_src=$WORKDIR/dpkg-status.$$
    rm -rf "$status_src"
    if have unsquashfs &&
       unsquashfs -q -n -f -d "$status_src" "$base" var/lib/dpkg/status >/dev/null 2>&1 &&
       [[ -s "$status_src/var/lib/dpkg/status" ]]; then
        cp "$status_src/var/lib/dpkg/status" "$WORKDIR/status"
    else
        warn "could not read the package list out of $(basename "$base") -- staging the full closure"
        : > "$WORKDIR/status"
    fi
    rm -rf "$status_src"

    local helper=$STAGE/.apt-helper.sqsh
    if [[ ! -f "$helper" ]]; then
        log "importing the apt helper image ($HELPER_URI)"
        ## Native architecture on purpose: this one does get executed.
        local save=$arch
        arch=$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/')
        import "$helper" "$HELPER_URI" || { arch=$save; return 1; }
        arch=$save
    fi

    rm -rf "$dir"; mkdir -p "$dir"
    local name="aptfetch-$$"
    enroot remove -f "$name" >/dev/null 2>&1
    enroot create --name "$name" "$helper" || return 1

    ## The heredoc runs as root inside the helper. /out is the staging
    ## directory, /status the base image's package list.
    enroot start --root --rw \
        --mount "$dir:/out:none x-create=dir,bind" \
        --mount "$WORKDIR/status:/status:none x-create=file,bind" \
        "$name" bash -euxc "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq --no-install-recommends apt-utils

            ## apt refuses to start if either partial/ is absent -- 'Lists
            ## directory ... is missing' / 'Archives directory ... is
            ## missing'. /out/partial matters because Dir::Cache::archives
            ## points there, not at the /apt tree.
            mkdir -p /apt/lists/partial /apt/state /out/partial
            cp /status /apt/state/status
            cat > /apt/sources.list <<EOF
deb ${mirror} ${UBUNTU_SUITE} main universe
deb ${mirror} ${UBUNTU_SUITE}-updates main universe
deb ${mirror} ${UBUNTU_SUITE}-security main universe
EOF
            apt() {
                command apt-get \
                    -o APT::Architecture=${dpkg_arch} \
                    -o APT::Architectures=${dpkg_arch} \
                    -o Dir::State=/apt/state \
                    -o Dir::State::Lists=/apt/lists \
                    -o Dir::State::status=/apt/state/status \
                    -o Dir::Cache=/apt \
                    -o Dir::Cache::archives=/out \
                    -o Dir::Etc::sourcelist=/apt/sources.list \
                    -o Dir::Etc::sourceparts=/dev/null \
                    -o APT::Get::AllowUnauthenticated=true \
                    -o Acquire::AllowInsecureRepositories=true \
                    \"\$@\"
            }
            apt update -qq
            apt install -y --no-install-recommends --download-only ${pkgs}

            ## Turn the download directory into something apt can read as a
            ## repository, so the node side resolves against it normally
            ## instead of us guessing an install order for dpkg.
            rm -rf /out/partial /out/lock
            cd /out && apt-ftparchive packages . > Packages
        " || {
            enroot remove -f "$name" >/dev/null 2>&1
            warn "staging $dpkg_arch packages failed -- the trace above is from inside the helper"
            warn "container, so the last command shown is the one that broke. Common causes:"
            warn "  * this machine cannot reach ${mirror} (proxy? \$http_proxy is not passed in)"
            warn "  * the package names in spec() are wrong for ${UBUNTU_SUITE}"
            return 1
        }

    enroot remove -f "$name" >/dev/null 2>&1
    rm -f "$WORKDIR/status"
    if [[ ! -s "$dir/Packages" ]]; then
        warn "no package index produced in $dir"
        return 1
    fi
    echo "staged $(find "$dir" -name '*.deb' | wc -l) packages in $dir"
}

## Write the script the build pass runs inside the container. It is generated
## rather than kept as a file because the package list and build steps live in
## spec() next to the rest of each image's definition.
write_build_script() {
    local path="$1" pkgs="$2" cmds="$3"
    cat > "$path" <<EOF
#!/bin/bash
## Generated by build_containers.sh -- runs as root inside the base image on a
## node of the target architecture. Do not edit here; edit spec().
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

## The node has no route to the internet. /deps is the package set staged by
## the fetch pass; trusted=yes because it is a local directory we produced, not
## a signed archive.
rm -f /etc/apt/sources.list
rm -rf /etc/apt/sources.list.d
mkdir -p /etc/apt/sources.list.d
echo 'deb [trusted=yes] file:/deps ./' > /etc/apt/sources.list.d/staged.list
apt-get -o Acquire::Retries=0 update
apt-get install -y --no-install-recommends ${pkgs}

## Build out of a container-local copy. /src is on NFS and read-only in spirit
## -- an in-source cmake would otherwise litter it and make repeat runs
## depend on which node went first.
cp -a /src /build
cd /build
${cmds}

## /deps and /src are bind mounts of the shared staging directory -- removing
## anything under them would destroy the stage for every other node. Only the
## local copy goes.
cd /
rm -rf /build
EOF
    chmod +x "$path"
}

fetch_source_image() {
    local img="$1" st="$STAGE/$img"
    spec "$img" || return 1
    mkdir -p "$st" || return 1

    log "$img: fetching base image, sources and packages for $arch"
    import "$st/base-${arch}.sqsh" "$BASE_URI" || return 1
    fetch_repo "$REPO" "$st/src" "$REF" || return 1
    fetch_debs "$st/debs" "$PKGS" "$st/base-${arch}.sqsh" || return 1
    write_build_script "$st/build.sh" "$PKGS" "$BUILD_CMDS"

    echo "$img: staged in $st -- now run '$0 -B $img' on a $arch node"
}

## ── build pass (compute node) ─────────────────────────────────────────────

build_from_stage() {
    local img="$1" out="$2" st="$STAGE/$img" name="build-$img-$$" tmp rc=0

    ## Both of these fail just this image rather than the whole run, so a
    ## plain invocation still gets through the registry pulls.
    if [[ ! -f "$st/build.sh" || ! -f "$st/base-${arch}.sqsh" ]]; then
        warn "$img: nothing staged for $arch in $st"
        warn "    run '$0 -a $arch -F $img' on the headnode first"
        return 1
    fi

    ## A cross build would produce binaries the nodes cannot run, and the whole
    ## point of the split is that this pass is native.
    local here
    here=$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/')
    if [[ "$here" != "$arch" ]]; then
        warn "$img: this is a $here machine, cannot build $arch here"
        warn "    run the build pass on a $arch node: srun -N1 $0 -B $img"
        return 1
    fi

    log "$img: building $arch natively on $(hostname -s)"
    enroot remove -f "$name" >/dev/null 2>&1
    enroot create --name "$name" "$st/base-${arch}.sqsh" || return 1

    ## The three inputs go in read-only. The staging directory is shared by
    ## every node that runs this pass, and a build that scribbles on it would
    ## take the others down with it.
    enroot start --root --rw \
        --mount "$st/src:/src:none x-create=dir,bind,ro" \
        --mount "$st/debs:/deps:none x-create=dir,bind,ro" \
        --mount "$st/build.sh:/build.sh:none x-create=file,bind,ro" \
        "$name" bash /build.sh || rc=1

    if [[ "$rc" -eq 0 ]]; then
        ## Same temp-then-move as import(), for the same reason.
        tmp="$DEST/.$(basename "$out").$$"
        enroot export -f -o "$tmp" "$name" && mv -f "$tmp" "$out" || { rm -f "$tmp"; rc=1; }
    fi

    enroot remove -f "$name" >/dev/null 2>&1
    return "$rc"
}

## ── hpc-benchmarks ────────────────────────────────────────────────────────
## Public NGC image, no credentials needed. Covers allreduce, alltoall, both
## -nonvlink variants, hpl, cublasmatmul, and stream -- six of the jobs, so
## this is the one with the most to gain from a local copy. Multi-arch on the
## registry, so the ARM build is a plain import with --arch.
build_hpc_benchmarks() {
    local out="$1"
    [[ "$MODE" == build ]] && return 0
    log "hpc-benchmarks: importing nvcr.io#nvidia/hpc-benchmarks:${HPC_BENCHMARKS_TAG} ($arch)"
    import "$out" "docker://nvcr.io#nvidia/hpc-benchmarks:${HPC_BENCHMARKS_TAG}"
}

## ── nvbandwidth ───────────────────────────────────────────────────────────
## Prebuilt images exist in a private NGC org. If we can read it that is a
## straight import and the build pass has nothing to do; otherwise it falls
## back to the two-pass source build.
build_nvbandwidth() {
    local out="$1" uri="docker://nvcr.io#${NVBANDWIDTH_ORG}/nvbandwidth-single-node:${NVBANDWIDTH_VERSION}-${arch}"

    if [[ "$MODE" != build ]]; then
        log "nvbandwidth: trying the NGC org image"
        if import "$out" "$uri"; then
            return 0
        fi
        warn "nvbandwidth: NGC org import failed (no access to org ${NVBANDWIDTH_ORG}?) -- staging a source build"
        fetch_source_image nvbandwidth || return 1
    fi
    [[ "$MODE" == fetch ]] && return 0
    build_from_stage nvbandwidth "$out"
}

## ── nvloom ────────────────────────────────────────────────────────────────
## No image published anywhere. The repo carries a Dockerfile it describes as a
## sample -- spec() follows its package list and build steps, but read it again
## when bumping the version.
build_nvloom() {
    local out="$1"
    [[ "$MODE" == build ]] || fetch_source_image nvloom || return 1
    [[ "$MODE" == fetch ]] && return 0
    build_from_stage nvloom "$out"
}

## ── mnubergemm ────────────────────────────────────────────────────────────
## NVIDIA-internal, not distributed publicly and not buildable from anything we
## have. Nothing to do but say so.
build_mnubergemm() {
    local out="$1"
    [[ "$MODE" == build ]] && return 0
    warn "mnubergemm is NVIDIA-internal -- there is no public source or registry to build from."
    warn "Obtain the image through the internal channel for your platform and import it:"
    warn "    enroot import -o $out dockerd://<image>:<tag>"
    warn "The version and -arch suffix must match the nodes under test."
    return 1
}

while getopts ':fld:a:FBh' opt; do
    case "$opt" in
        f) FORCE=1 ;;
        l) LIST=1 ;;
        d) DEST="$OPTARG" ;;
        a) arch="$OPTARG" ;;
        F) MODE=fetch ;;
        B) MODE=build ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))

[[ -n "$(enroot_arch "$arch")" ]] || die "unknown architecture: $arch (want arm or x86)"

images=("$@")
[[ "${#images[@]}" -eq 0 ]] && images=(hpc-benchmarks nvbandwidth nvloom mnubergemm)

for img in "${images[@]}"; do
    image_file "$img" >/dev/null || die "unknown image: $img"
done

## The build pass only ever has something to do for the source-built images.
if [[ "$MODE" == build ]]; then
    filtered=()
    for img in "${images[@]}"; do
        from_source "$img" && filtered+=("$img")
    done
    [[ "${#filtered[@]}" -gt 0 ]] || die "nothing to build: -B applies to nvbandwidth and nvloom only"
    images=("${filtered[@]}")
fi

if [[ "$LIST" -eq 1 ]]; then
    printf '%-16s %-52s %-24s %s\n' IMAGE FILE STATUS STAGED
    for img in "${images[@]}"; do
        f=$(image_file "$img")
        if [[ -f "$DEST/$f" ]]; then
            status="present ($(du -h "$DEST/$f" | cut -f1))"
        else
            status=missing
        fi
        staged=-
        if from_source "$img"; then
            if [[ -f "$STAGE/$img/build.sh" && -f "$STAGE/$img/base-${arch}.sqsh" ]]; then
                staged="staged for $arch"
            else
                staged="not staged"
            fi
        fi
        printf '%-16s %-52s %-24s %s\n' "$img" "$f" "$status" "$staged"
    done
    exit 0
fi

have enroot || die "enroot is not installed"
mkdir -p "$DEST" "$WORKDIR" "$ENROOT_CACHE_PATH" "$ENROOT_TEMP_PATH" \
         "$ENROOT_DATA_PATH" "$ENROOT_RUNTIME_PATH" ||
    die "cannot create $DEST -- check write access"
[[ "$MODE" == build ]] || mkdir -p "$STAGE" || die "cannot create $STAGE -- check write access"

failed=()
for img in "${images[@]}"; do
    out="$DEST/$(image_file "$img")"

    ## The fetch pass restages regardless of whether the .sqsh exists; it is
    ## the build pass that the finished image would make redundant.
    if [[ -f "$out" && "$FORCE" -eq 0 && "$MODE" != fetch ]]; then
        echo "$img: $(basename "$out") already present, skipping (-f to rebuild)"
        continue
    fi

    if "build_${img//-/_}" "$out"; then
        [[ "$MODE" == fetch ]] || echo "$img: $out"
    else
        failed+=("$img")
    fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
    warn "did not build: ${failed[*]}"
    exit 1
fi

if [[ "$MODE" == fetch ]]; then
    log "fetched -- $STAGE"
    exit 0
fi

log "done -- $DEST"
ls -lh "$DEST"/*.sqsh 2>/dev/null

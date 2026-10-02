#!/bin/bash
#
# Usage: check_ib.sh <node> [container]
#
# Does the container see the same HCAs the host does, and will NCCL use them?
# The four failure modes and the case numbers printed below are documented in
# docs/how-to/diagnose-ib-visibility.md; the host-vs-container split
# itself is docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
#
# One node at a time on purpose: the host selection is read back here and
# pinned into the container run, so both sections describe the same machine.
#
# Read-only. Runs interactive sruns, writes nothing, drains nothing.

set -u

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"

node="${1:-}"
if [[ -z "$node" ]]; then
    echo "Usage: ${0##*/} <node> [container]" >&2
    exit 1
fi

if ! command -v srun &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

## Explicit image, if given. Otherwise resolved on the NODE in section 1 below.
CONT="${2:-}"

## Must be the same filter and probe the jobs use, or this is not testing what
## runs. See docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
HCA_LIB="$JOBS_DIR/nccl-hca.sh"
if [[ ! -f "$HCA_LIB" ]]; then
    echo "ERROR: missing $HCA_LIB -- it carries the HCA filter and the container" >&2
    echo "       probe the jobs use, and probing with a different one would not" >&2
    echo "       be testing what runs." >&2
    exit 1
fi

echo "=== ib-visibility: $node"

## ── 1. Host side ──────────────────────────────────────────────────────────
## srun rather than a fan-out: a remote shell reaches the host but sits outside Slurm's view.
## nccl_hca_detect runs INSIDE the payload so the selection is the node's own,
## not one recomputed against the head node's PCI bus; the fixed-format echo is
## read back below to pin the container run to the same devices.
host_out=$(srun --ntasks=1 -w "$node" --export=ALL bash -c '
source '"$HCA_LIB"'

echo "## PCI Infiniband devices, functions per device"
echo "##   (4 functions = the NVSwitch-attached HCA, which the filter drops)"
lspci -D 2>/dev/null | grep -i Infiniband | awk "{print \$1}" | cut -d. -f1 \
    | sort | uniq -c | sed "s/^/     /"
echo "## /sys/class/infiniband: $(ls /sys/class/infiniband 2>/dev/null | paste -sd" ")"
echo "## /dev/infiniband:       $(ls /dev/infiniband 2>/dev/null | paste -sd" ")"

if nccl_hca_detect; then
    echo "## nccl_hca_detect picked: $NCCL_IB_HCA"
else
    echo "## nccl_hca_detect picked: (nothing)"
    echo "##   CASE 1 -- no compute-plane HCA survives the bond/NVSwitch filter."
    echo "##   The jobs abort here and write FAIL. Nothing below will help."
fi

## A present-but-LinkDown device is invisible to NCCL exactly as an absent one
## is, so print the state, not just the name.
echo "## port state:"
if command -v ibv_devinfo >/dev/null 2>&1; then
    ibv_devinfo 2>/dev/null | awk "
        /^hca_id:/    {d=\$2}
        /^[[:space:]]*port:/ {p=\$2}
        /state:/      {s=\$2\" \"\$3}
        /link_layer:/ {print \"     \" d \" port\" p \" \" s \" \" \$2}"
else
    for f in /sys/class/infiniband/*/ports/*/state; do
        [[ -e "$f" ]] || continue
        p=${f%/state}
        echo "     ${p}: $(cat "$f" 2>/dev/null)" | sed "s#/sys/class/infiniband/##;s#/ports/#  port #"
    done
fi

## Image path and arch resolved HERE, on the node, then read back on the head
## node: NODE_CONTAINER_DIR is node-local, so testing it on the head node picks
## a path that is real where it was looked for and absent where it runs. Same
## fallback the jobs use -- see docs/explanation/containers.md#how-the-caching-works.
img=nvidia+hpc-benchmarks+26.02-$(uname -m | sed "s/aarch64/arm/;s/x86_64/x86/").sqsh
if [[ -f '"$NODE_CONTAINER_DIR"'/$img ]]; then
    echo "CONTAINER='"$NODE_CONTAINER_DIR"'/$img"
else
    echo "CONTAINER='"$CONTAINER_DIR"'/$img"
    echo "## node-local '"$NODE_CONTAINER_DIR"'/$img is absent -- file_copy.sh has not"
    echo "##   reached this node. Falling back to the NFS copy, which is the same"
    echo "##   image; the job would do the same. Slower first start, nothing more."
fi

echo "HOSTSELECTED=$NCCL_IB_HCA"
' 2>&1)

echo
echo "---------------- HOST $node ----------------"
printf '%s\n' "$host_out" | grep -vE '^(HOSTSELECTED|CONTAINER)='

## Empty is a legitimate answer (case 1), passed through rather than defaulted:
## NCCL_IB_HCA="" means "any device" to NCCL, not "no devices".
host_hca=$(printf '%s\n' "$host_out" | sed -n 's/^HOSTSELECTED=//p' | tail -1)

## An explicit $2 wins; otherwise take what the node resolved.
[[ -n "$CONT" ]] || CONT=$(printf '%s\n' "$host_out" | sed -n 's/^CONTAINER=//p' | tail -1)
if [[ -z "$CONT" ]]; then
    echo
    echo "ERROR: the host srun produced no container path, so it did not run." >&2
    echo "       Its output is above; the container sections cannot be attempted." >&2
    exit 1
fi
echo "## container image: $CONT"

## ── 2. Container side ─────────────────────────────────────────────────────
## Same image, same mounts, same libibverbs call the benchmark makes. Anything
## that differs from section 1 is the bug.
echo
echo "---------------- CONTAINER on $node ----------------"
srun --ntasks=1 -w "$node" --export=ALL,NCCL_IB_HCA="$host_hca" \
     --container-image="$CONT" \
     --container-mounts=/dev/infiniband:/dev/infiniband \
     bash -c '
echo "## host picked NCCL_IB_HCA: ${NCCL_IB_HCA:-(empty -- NCCL would use ANY device)}"
echo "## /dev/infiniband:       $(ls /dev/infiniband 2>/dev/null | paste -sd" ")"
echo "## /sys/class/infiniband: $(ls /sys/class/infiniband 2>/dev/null | paste -sd" ")"

if ! command -v ibv_devinfo >/dev/null 2>&1; then
    echo "## ibv_devinfo is NOT in this image. sysfs can be read either way, but"
    echo "##   it says nothing about whether libibverbs can OPEN the device --"
    echo "##   which is the call NCCL makes and the one that fails."
    exit 0
fi

seen=$(ibv_devinfo -l 2>/dev/null | awk "NR > 1 {print \$1}" | paste -sd" ")
echo "## ibv_devinfo -l sees:   ${seen:-(none)}"
if [[ -z "$seen" ]]; then
    echo "##   CASE 2 -- the host has HCAs and the container has none. This is"
    echo "##   the same call NCCL makes, so NCCL will find nothing either."
    echo "##   Look at the bind mounts, not at the fabric."
    exit 0
fi

echo "## port state:"
ibv_devinfo 2>/dev/null | awk "
    /^hca_id:/    {d=\$2}
    /^[[:space:]]*port:/ {p=\$2}
    /state:/      {s=\$2\" \"\$3}
    /link_layer:/ {print \"     \" d \" port\" p \" \" s \" \" \$2}"

active=$(ibv_devinfo 2>/dev/null \
    | awk "/^hca_id:/{d=\$2} /state:.*PORT_ACTIVE/{print d}" | sort -u | paste -sd" ")
echo "## ACTIVE ports on:       ${active:-(none)}"
if [[ -z "$active" ]]; then
    echo "##   CASE 3 -- devices enumerate but no port is ACTIVE. NCCL skips"
    echo "##   those, and its log is then indistinguishable from having no"
    echo "##   device at all. This is a link/fabric problem, not a mount one."
fi

## The other half of case 3, and the one nothing else reports: the job pins NCCL
## to names computed on the HOST. Different names or a subset inside the
## container, and NCCL reports no device found while sitting on four good HCAs.
if [[ -n "${NCCL_IB_HCA:-}" ]]; then
    missing=
    for d in ${NCCL_IB_HCA//,/ }; do
        grep -qw -- "$d" <<<"$seen" || missing+=" $d"
    done
    if [[ -n "$missing" ]]; then
        echo "## MISMATCH -- pinned but not present in the container:$missing"
        echo "##   CASE 3 -- NCCL_IB_HCA names devices this container cannot see."
    else
        echo "## name match:            every pinned device is present here"
    fi
fi
'

## ── 3. What NCCL itself makes of it ───────────────────────────────────────
## Sections 1-2 describe the node; this asks the library, in the -nonvlink jobs'
## environment cut to one 8-byte message. The init log is the point, not the
## bandwidth, and NCCL_NET=IB with no fallback makes it fail loudly rather than
## quietly succeed over TCP.
##
## Filtered to the transport lines verdict.sh reads -- see
## docs/explanation/judging-benchmarks.md#judge-the-channels-never-the-plugin-registration -- plus
## pyxis, enroot and srun errors, so a run that never started a container cannot
## print an empty section that reads as "NCCL ran and said nothing".
echo
echo "---------------- NCCL init on $node ----------------"
nccl_out=$(
srun --mpi=pmix --ntasks=4 --gpus-per-node=4 -w "$node" \
     --export=ALL,NCCL_IB_HCA="$host_hca" \
     --cpu-bind=none --mem-bind=none \
     --container-image="$CONT" \
     --container-mounts=/dev/infiniband:/dev/infiniband \
     bash -c '
export NCCL_SOCKET_IFNAME=bond0 NCCL_DEBUG=INFO
export NCCL_P2P_DISABLE=1 NCCL_SHM_DISABLE=1 NCCL_NVLS_ENABLE=0 NCCL_MNNVL_ENABLE=0
export NCCL_IB_DISABLE=0 NCCL_NET=IB
allreduce_perf_mpi -b 8 -e 8 -f 2 -g 1' 2>&1 \
    | grep -E 'NET/IB|NET/Socket|Using network|NCCL WARN|No device found|Failed to initialize|^# Avg bus|via |pyxis|enroot|^srun: error' \
    | sort -u | sed 's/^/  /')

if [[ -n "$nccl_out" ]]; then
    printf '%s\n' "$nccl_out"
else
    echo "  (no matching lines -- the run produced no transport output and no"
    echo "   error either. Re-run this srun by hand without the grep.)"
fi

echo
echo "=== Read the sections in order. The first one that is wrong is the cause;"
echo "=== everything after it is a consequence. Case numbers above map to the"
echo "=== reasons verdict.sh reports in report_job-status.sh."

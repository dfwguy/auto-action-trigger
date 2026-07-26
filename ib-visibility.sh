#!/bin/bash
#
# Usage: ib-visibility.sh <node> [container]
#
# Answers one question, on one node, in under a minute: does the container see
# the same HCAs the host does, and will NCCL use them?
#
# This exists because the two NCCL -nonvlink jobs can fail for four different
# reasons that all read the same way from a bandwidth number, and telling them
# apart from a finished benchmark log means waiting an hour first:
#
#   1. the host has no compute-plane HCA at all    -- nccl_hca_detect finds none
#   2. the host has them, the container sees none  -- /dev/infiniband not bound
#                                                     into the container
#   3. the container sees them, NCCL finds none    -- no ACTIVE port, or the
#                                                     names pinned in
#                                                     NCCL_IB_HCA do not exist
#                                                     inside the container
#   4. all of it is visible and NCCL still declines to use it
#
# verdict.sh gates on 2 and 3 as separate reasons for exactly this purpose. A
# node reporting "no IB device visible to NCCL" rather than "no HCA visible
# inside the container" has already ruled out case 2 -- the container DID list
# devices -- so the answer is in case 3, and neither port state nor the
# host-vs-container name match is visible from an ssh session or from a
# bandwidth figure.
#
# One node at a time on purpose. The host selection is read back here and
# pinned into the container run, so the two sections are guaranteed to be
# describing the same machine; a nodelist would let them drift apart.
#
# Read-only. Runs interactive sruns, writes nothing, drains nothing.

set -u

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

node="${1:-}"
if [[ -z "$node" ]]; then
    echo "Usage: ${0##*/} <node> [container]" >&2
    exit 1
fi

if ! command -v srun &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

## Same image resolution as the -nonvlink sbatch files: node-local copy first,
## the NFS original as fallback. Overridable as $2 so a suspect image can be
## tested against a known-good one on the same node.
IMG=nvidia+hpc-benchmarks+26.02-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT="${2:-}"
if [[ -z "$CONT" ]]; then
    CONT=/tmp/containers/$IMG
    [[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
fi

## The jobs source this from the NFS path, and the probe text plus the HCA
## filter both have to be the ones the benchmark uses -- probing with a
## different rule would not test what actually runs.
HCA_LIB="$home/jobs/nccl-hca.sh"
if [[ ! -f "$HCA_LIB" ]]; then
    echo "ERROR: missing $HCA_LIB -- it carries the HCA filter and the container" >&2
    echo "       probe the jobs use, and probing with a different one would not" >&2
    echo "       be testing what runs." >&2
    exit 1
fi

echo "=== ib-visibility: $node"
echo "=== container:     $CONT"

## ── 1. Host side ──────────────────────────────────────────────────────────
## Through srun rather than ssh. ssh puts you on the host too, but it also puts
## you outside Slurm's view of the node, and the whole failure this script
## chases is one that looks fine from an ssh session.
##
## nccl_hca_detect is sourced and run INSIDE the payload so the selection is the
## one that node makes, not one recomputed on the head node against the head
## node's PCI bus. The chosen list is echoed in a fixed format and read back
## below to pin the container run to the same devices the job would use.
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

## A device that is present but LinkDown is invisible to NCCL in exactly the
## way a device that is absent is, so the state has to be printed, not just
## the name.
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

echo "HOSTSELECTED=$NCCL_IB_HCA"
' 2>&1)

echo
echo "---------------- HOST $node ----------------"
printf '%s\n' "$host_out" | grep -v '^HOSTSELECTED='

## Empty is a legitimate answer (case 1) and is passed through as empty rather
## than defaulted: NCCL_IB_HCA="" does not mean "no devices" to NCCL, it means
## "any device", so the container section below has to know the difference.
host_hca=$(printf '%s\n' "$host_out" | sed -n 's/^HOSTSELECTED=//p' | tail -1)

## ── 2. Container side ─────────────────────────────────────────────────────
## Same image, same mounts, and the same libibverbs call the benchmark makes.
## Anything that differs from the section above is the bug.
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

## The other half of case 3, and the one nothing else reports: the job pins
## NCCL to names computed on the HOST. If the container enumerates the same
## hardware under different names, or a subset, NCCL is pinned to devices that
## do not exist in there and reports no device found while sitting on four
## perfectly good HCAs.
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
## The two sections above describe the node; this one asks the library, in the
## same environment the -nonvlink jobs set, cut to a single 8-byte message so it
## returns in seconds. The init log is the point, not the bandwidth.
##
## NCCL_NET=IB with no fallback, matching the jobs: this is meant to fail loudly
## here rather than quietly succeed over TCP.
##
## Output is filtered to the transport lines. The full log is enormous and the
## four lines that decide the verdict -- what plugin loaded, what network was
## chosen, and what each channel actually used -- are what verdict.sh reads.
echo
echo "---------------- NCCL init on $node ----------------"
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
    | grep -E 'NET/IB|NET/Socket|Using network|NCCL WARN|No device found|Failed to initialize|^# Avg bus|via ' \
    | sort -u | sed 's/^/  /'

echo
echo "=== Read the sections in order. The first one that is wrong is the cause;"
echo "=== everything after it is a consequence. Case numbers above map to the"
echo "=== reasons verdict.sh reports in status-check.sh."

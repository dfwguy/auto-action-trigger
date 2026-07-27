#!/bin/bash
#
# Compute-plane HCA discovery for the NCCL -nonvlink jobs. Sourced by
# jobs/nvl72/allreduce-nonvlink.sbatch and jobs/nvl72/alltoall-nonvlink.sbatch, which had
# byte-identical copies of this until now. The same lspci/uniq -c incantation
# also appears three times in actions/node_health.sh; those are next.
#
# Two things live here, and the split between them is the point.
#
# nccl_hca_detect runs on the HOST and picks the devices to pin NCCL_IB_HCA to.
# NCCL_HCA_PROBE runs INSIDE the CONTAINER and reports what is actually visible
# there. Those are not the same question, and answering only the first is what
# sent the whole benchmark over bond0 for weeks: the host list was correct the
# entire time, and enroot gave the container a fresh /dev with no HCA character
# devices in it, so ibv_get_device_list came back empty and NCCL logged
# `NET/IB : No device found.` before dropping to TCP. Anyone checking by hand
# over ssh saw a perfectly good HCA list and had no reason to look further.

## Pin the data path to the compute-plane HCAs. Two device classes get dropped:
## the NVSwitch-attached HCA, which presents as 4 functions on one PCIe device
## (node_health.sh bypasses it the same way), and mlx5_bond_*, which backs
## bond0 -- that is the OOB path, not the fabric under test.
##
## Sets and exports NCCL_IB_HCA. Returns 1 if nothing survived the filter,
## because NCCL_IB_HCA="" does not mean "no devices" to NCCL -- it means "any
## device, including the two classes we just excluded".
nccl_hca_detect() {
    NCCL_IB_HCA=$(
        nvswitch_bdf=$(lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d. -f1 \
            | sort | uniq -c | awk '$1 == 4 {print $2}')
        for path in /sys/class/infiniband/*; do
            dev=${path##*/}
            [[ $dev == *bond* ]] && continue
            bdf=$(basename "$(dirname "$(dirname "$(readlink -f "$path")")")")
            grep -qxF "${bdf%.*}" <<<"$nvswitch_bdf" && continue
            echo "$dev"
        done | sort -t'_' -k2n | paste -s -d','
    )
    export NCCL_IB_HCA
    [[ -n "$NCCL_IB_HCA" ]]
}

## Everything the host knows, before the container is involved. Printed even on
## a passing run: when a result is questioned weeks later, "which HCAs did this
## actually use" should be answerable from the result file alone.
nccl_hca_report_host() {
    echo "INFO: host /sys/class/infiniband: $(ls /sys/class/infiniband 2>/dev/null | paste -sd' ')"
    echo "INFO: host /dev/infiniband: $(ls /dev/infiniband 2>/dev/null | paste -sd' ')"
    echo "INFO: forcing collectives over HCAs: $NCCL_IB_HCA"
}

## Run inside the container, as `bash -c "$NCCL_HCA_PROBE"`. Reports what the
## container can see rather than what the host could, and reports it from
## ibv_devinfo where possible -- that is the same libibverbs call NCCL makes, so
## it fails in the same way NCCL will rather than merely describing the
## filesystem next to it.
##
## The last line is a fixed format on purpose: verdict.sh gates on it, so a
## container with no visible HCA is a FAIL with a named reason instead of a
## socket run that has to be spotted by its bandwidth.
read -r -d '' NCCL_HCA_PROBE <<'PROBE' || true
echo "INFO: container NCCL_IB_HCA: ${NCCL_IB_HCA:-(unset)}"
echo "INFO: container /dev/infiniband: $(ls /dev/infiniband 2>/dev/null | paste -sd' ')"
echo "INFO: container /sys/class/infiniband: $(ls /sys/class/infiniband 2>/dev/null | paste -sd' ')"
if command -v ibv_devinfo >/dev/null 2>&1; then
    hcas=$(ibv_devinfo -l 2>/dev/null | awk 'NR > 1 {print $1}' | paste -sd' ')
    via=ibv_devinfo
else
    hcas=$(ls /sys/class/infiniband 2>/dev/null | paste -sd' ')
    via=/sys/class/infiniband
fi
echo "INFO: container sees HCAs (via $via): ${hcas:-(none)}"
PROBE

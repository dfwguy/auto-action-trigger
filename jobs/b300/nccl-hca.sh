#!/bin/bash
#
# Compute-plane HCA discovery for the NCCL -nonvlink jobs. Host detection and
# container probe answer different questions; see
# docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.

## Drops the NVSwitch-attached HCA (4 functions on one PCIe device) and
## mlx5_bond_*, which backs the OOB bond0. Returns 1 if nothing survived: an
## empty NCCL_IB_HCA means "any device" to NCCL, not "no devices".
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

## Printed even on a passing run, so a result file stands on its own.
nccl_hca_report_host() {
    echo "INFO: host /sys/class/infiniband: $(ls /sys/class/infiniband 2>/dev/null | paste -sd' ')"
    echo "INFO: host /dev/infiniband: $(ls /dev/infiniband 2>/dev/null | paste -sd' ')"
    echo "INFO: forcing collectives over HCAs: $NCCL_IB_HCA"
}

## Run inside the container, as `bash -c "$NCCL_HCA_PROBE"`. Prefers
## ibv_devinfo -- the same libibverbs call NCCL makes. The last line is a fixed
## format because verdict.sh gates on it. See
## docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
# shellcheck disable=SC2034  # read by the -nonvlink sbatch files that source this
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

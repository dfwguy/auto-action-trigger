#!/bin/bash
# banner: ########INFO: Check PCIe MRRS (Expected: all 4096, but on BXX/HXX some&lt;4&gt; with 512 is expected)

if [[ -n "${BRINGUP_PCIE_LSPCI_SNAPSHOT:-}" && -r "$BRINGUP_PCIE_LSPCI_SNAPSHOT" ]]; then
  snapshot=$(<"$BRINGUP_PCIE_LSPCI_SNAPSHOT")
else
  snapshot=$(sudo -n lspci -vvv)
fi

device_section() {
  awk -v id="$1" '
    $1 == id { emit=1; print; next }
    emit && /^[^[:space:]]/ { exit }
    emit { print }
  ' <<<"$snapshot"
}

lspci -d 15b3: -nn | awk '{print $1}' \
  | while read -r i; do device_section "$i"; done \
  | grep -o "MaxReadReq.*" \
  | awk '{print $(NF-1)}' | sort | uniq -c

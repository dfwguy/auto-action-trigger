#!/bin/bash
# banner: ########INFO: Check PCIe LnkCap+LnkStat (Expected: No issue found, but on BXX/HXX xx:xx.{0..3} shown is expected)

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

if [ "$(uname -m)" == x86_64 ]; then
  lspci -d 15b3: -nn | awk '{print $1}' \
    | while read -r i; do
        cnt=$(device_section "$i" \
          | grep -e LnkCap: -e LnkSta: \
          | grep -o "Speed.*" \
          | awk -F',' '{print $1, $2}' \
          | tr -s ' ' \
          | sort | uniq -c | wc -l)
        if [ "$cnt" -ne 1 ]; then
          echo "$i"
        fi
      done
elif [ "$(uname -m)" == aarch64 ]; then
  lspci -d 15b3: -nn | grep controller | awk '{print $1}' \
    | while read -r i; do
        cnt=$(device_section "$i" \
          | grep -e LnkCap: -e LnkSta: \
          | grep -o "Speed.*" \
          | awk -F',' '{print $1, $2}' \
          | tr -s ' ' \
          | sort | uniq -c | wc -l)
        if [ "$cnt" -ne 1 ]; then
          echo "$i"
        fi
      done
fi

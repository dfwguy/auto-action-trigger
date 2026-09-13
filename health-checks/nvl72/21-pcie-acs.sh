#!/bin/bash
# banner: ########INFO: Check PCIe ACS (Expected: All same brand nodes the same)

if [[ -n "${BRINGUP_PCIE_LSPCI_SNAPSHOT:-}" && -r "$BRINGUP_PCIE_LSPCI_SNAPSHOT" ]]; then
  cat -- "$BRINGUP_PCIE_LSPCI_SNAPSHOT"
else
  sudo -n lspci -vvv
fi | grep 'ACSCtl:.*SrcValid-' | wc -l

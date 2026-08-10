#!/bin/bash
# banner: ########INFO: Check BMC firmware (Expected: all nodes the same)
#
# Timed out, not left to block -- a wedged BMC answers neither way. See
# docs/explanation/node-inventory.md#a-missing-value-still-gets-a-line.

out=$(timeout 15 sudo -n ipmitool mc info 2>/dev/null)

if [ -n "$out" ]; then
  echo "$out" | grep -E '^(Firmware Revision|Manufacturer Name|Product Name)' |
    sed 's/  */ /g' | sort
else
  echo 'ipmitool mc info said nothing in 15s -- no BMC, no kernel IPMI device, or the BMC is wedged'
fi

#!/bin/bash
# banner: ########INFO: Check IB FW (Expected: All nodes have the same FW version)

for i in /sys/class/infiniband/*; do
  printf "%50s%15s\n" "${i}/fw_ver" "$( <"${i}/fw_ver" )"
done

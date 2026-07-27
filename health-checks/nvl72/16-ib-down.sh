#!/bin/bash
# banner: ########INFO: Check IB Link Down status (Expected: No issue found)

# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
ls -l /sys/class/infiniband \
  | grep -v $((lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
    | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
    | xargs -I {} echo "-e {}.") \
  | grep infiniband | awk -F'/' '{print $(NF-2),$NF}' \
  | while read -r bdf dev; do
      ret=$(mlxlink -d "$bdf" 2>&1 | grep Recommendation | cut -f2- -d ':' \
        | grep -v 'No issue was observed' || true)
      if [ "X$ret" != "X" ]; then
        echo "${dev}:${ret}"
      fi
    done | paste -s -d','

#!/bin/bash
# banner: ########INFO: Check IB Link Down status (Expected: No issue found)

# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
# SC2010: `ls -l` prints the symlink targets carrying the PCI path a glob cannot.
# SC2046: splitting is the point — quoting collapses the per-HCA `-e <bdf>.`
# pairs into one pattern and stops excluding those ports on real hardware.
# shellcheck disable=SC2010,SC2046
ls -l /sys/class/infiniband \
  | grep -v $( (lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
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

#!/bin/bash
# banner: ########INFO: Check IB Link Down status (Expected: No issue found)

# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
#
# SC2010: the entries under /sys/class/infiniband are kernel-generated device
# names, so the usual worry about spaces and odd characters does not apply. The
# `ls -l` is also doing real work here beyond listing — the symlink targets it
# prints are what carry the PCI path that the awk below pulls the BDF out of, and
# a glob would not give us those.
#
# SC2046: the word splitting is the point. The substitution expands to a run of
# `-e <bdf>.` pairs that `grep -v` has to see as separate arguments, one per
# nvswitch-connected HCA. Quoting it collapses them into a single pattern, and
# the check would quietly stop excluding those ports on real hardware.
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

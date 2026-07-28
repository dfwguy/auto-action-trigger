#!/bin/bash
# banner: ########INFO: Check IB PKEY (Expected: All nodes have the same PKEY)

# The inner substitution builds a list of "-e <bdf>." arguments for grep -v, one
# per nvswitch-connected PCI function, so the split into separate words is the
# point: quoting it would hand grep a single pattern and stop the exclusion.
# The ls -l is parsed for its symlink targets, which a glob would not give us;
# the entries are kernel-generated infiniband device names, so there is nothing
# in them for grep to trip over.
# shellcheck disable=SC2046,SC2010
for i in $(
  ls -l /sys/class/infiniband \
    | grep -v $( (lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
      | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
      | xargs -I {} echo "-e {}.") \
    | grep infiniband | awk -F'/' '{print $NF}' \
    | grep -v bond_ | sort -t'_' -k2n
); do
  ret=$(cat /sys/class/infiniband/${i}/ports/1/pkeys/* \
    | grep -E -v '0x0000' | sort | uniq | paste -s -d',')
  if [ -n "$ret" ]; then
    echo "${i}: ${ret}"
  fi
done || true

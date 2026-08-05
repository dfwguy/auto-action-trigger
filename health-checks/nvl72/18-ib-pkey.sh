#!/bin/bash
# banner: ########INFO: Check IB PKEY (Expected: All nodes have the same PKEY)

# SC2046: the word split is the point -- quoting hands grep -v one pattern
# instead of the "-e <bdf>." list. SC2010: ls -l is parsed for symlink targets,
# which a glob would not give us. See docs/reference/health-checks.md.
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

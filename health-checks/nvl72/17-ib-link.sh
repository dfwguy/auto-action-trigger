#!/bin/bash
# banner: ########INFO: Check IB Link Down counters (Expected: No issue found)

# Skip the 4 HCA ports wired to the nvswitch on B200/B300.
# SC2010: ls -l carries the symlink targets the filter matches on, and sysfs
# names are kernel-generated. SC2046: the inner expansion must stay unquoted so
# grep -v sees one "-e <bdf>." per argument; quoting kills the exclusion.
# shellcheck disable=SC2010,SC2046
for dev in $(
  ls -l /sys/class/infiniband \
    | grep -v $( (lspci -D | grep -i Infiniband | awk '{print $1}' | cut -d '.' -f 1 \
      | sort | uniq -c | grep -w 4 || echo NONE) | awk '{print $NF}' \
      | xargs -I {} echo "-e {}.") \
    | grep infiniband | awk -F'/' '{print $NF}'
); do
  link_downed=$(</sys/class/infiniband/${dev}/ports/1/counters/link_downed)
  symbol_error=$(</sys/class/infiniband/${dev}/ports/1/counters/symbol_error)
  if [[ ${link_downed} -ne 0 || ${symbol_error} -ne 0 ]]; then
    echo "${dev}:link_downed=${link_downed},symbol_error=${symbol_error}"
  fi
done

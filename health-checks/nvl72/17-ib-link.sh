#!/bin/bash
# banner: ########INFO: Check IB Link Down counters (Expected: No issue found)

# Bypass those 4 ports IB HCA is connected to nvswitch on B200/B300.
# The names being filtered are kernel-generated sysfs device names, so they
# never contain spaces or globbing characters; ls is safe here, and its long
# form is what carries the symlink targets the filter matches against (SC2010).
# The inner substitution deliberately expands unquoted: it emits one
# "-e <bdf>." word per nvswitch-connected PCI function, and grep -v has to
# receive them as separate arguments. Quoting it would collapse them into a
# single argument and the exclusion would silently stop working (SC2046).
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

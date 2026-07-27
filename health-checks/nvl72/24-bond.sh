#!/bin/bash
# banner: ########INFO: Check Bond interfaces (Expected: all nodes the same)

for i in /proc/net/bonding/*; do
  {
    ethtool "${i##*/}" | grep -e Speed -e Link
    echo '==DETAILS=='
    grep -e 'Bonding Mode' -e 'Transmit Hash Policy' "$i"
    for j in $(grep 'Slave Interface' "$i" | awk '{print $NF}' | sort); do
      grep -A5 "$j" "$i" \
        | grep -e 'Slave Interface' -e 'MII Status' -e 'Speed' \
        | paste -s -d' '
    done
  } | xargs -I {} echo "${i}: {}"
done

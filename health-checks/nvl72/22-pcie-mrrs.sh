#!/bin/bash
# banner: ########INFO: Check PCIe MRRS (Expected: all 4096, but on BXX/HXX some&lt;4&gt; with 512 is expected)

lspci -d 15b3: -nn | awk '{print $1}' \
  | xargs -I {} sudo -n lspci -s {} -vvv \
  | grep -o "MaxReadReq.*" \
  | awk '{print $(NF-1)}' | sort | uniq -c

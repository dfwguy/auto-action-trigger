#!/bin/bash
# banner: ########INFO: Check NUMA

numactl -H | grep size: | grep -v ' 0 MB' \
  | awk '{print "N"$2"="int($(NF-1)/1000)"GB"}' | paste -s -d','

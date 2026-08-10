#!/bin/bash
# banner: ########INFO: Check HPC-X version (Expected: all nodes the same)

found=$(find /opt -maxdepth 1 -name 'hpcx*' -printf '%f\n' 2>/dev/null | sort | paste -s -d',')

if [ -n "$found" ]; then
  echo "$found"
else
  echo 'no /opt/hpcx* -- HPC-X not installed here, or installed outside /opt'
fi

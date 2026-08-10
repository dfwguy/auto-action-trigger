#!/bin/bash
# banner: ########INFO: Check OS release (Expected: all nodes the same distribution and version)

if [ -r /etc/os-release ]; then
  grep -E '^(ID|VERSION_ID)=' /etc/os-release | sort | paste -s -d' '
else
  echo 'no /etc/os-release -- distribution not reported'
fi

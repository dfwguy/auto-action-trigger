#!/bin/bash
# banner: ########INFO: Check IMEX version (Expected: all nodes the same on GBXX)

if [ "$(uname -m)" == aarch64 ]; then
  if command -v nvidia-imex >/dev/null 2>&1; then
    nvidia-imex --version
  else
    echo 'nvidia-imex not installed'
  fi
fi

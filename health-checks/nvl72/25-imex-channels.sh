#!/bin/bash
# banner: ########INFO: Check IMEX channel devices (Expected: At least one channel exist on GBXX)

if [ "$(uname -m)" == aarch64 ]; then
  ls -1 /dev/nvidia-caps-imex-channels/ 2>/dev/null || true
fi

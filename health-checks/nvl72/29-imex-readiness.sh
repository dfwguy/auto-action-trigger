#!/bin/bash
# banner: #########INFO: Check IMEX readiness (Expected: imex is READY on GBXX)

if [ "$(uname -m)" == aarch64 ]; then
  nvidia-imex-ctl -q 2>&1 || true
fi

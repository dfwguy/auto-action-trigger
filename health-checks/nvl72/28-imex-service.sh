#!/bin/bash
# banner: ########INFO: Check IMEX service status (Expected: 2 ports up and service is active on GBXX)

if [ "$(uname -m)" == aarch64 ]; then
  ss -lntp | grep nvidia-imex | grep -v nv-hostengine | wc -l
  systemctl is-active nvidia-imex.service || true
  ls /cm/local/apps/slurm/var/*/*imex* 2>/dev/null || true
fi

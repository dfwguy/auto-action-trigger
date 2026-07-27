#!/bin/bash
# banner: ########INFO: Check IMEX profile

if [ "$(uname -m)" == aarch64 ]; then
  grep -E "^(SERVER_PORT|IMEX_CMD_PORT|IMEX_CMD_ENABLED|IMEX_CMD_BIND_INTERFACE_IP)=" \
    /etc/nvidia-imex/config.cfg 2>/dev/null | paste -s -d' ' || true
fi

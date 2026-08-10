#!/bin/bash
# banner: ########INFO: Check Fabric Manager version (Expected: all nodes the same, and matching the driver)

if command -v nv-fabricmanager >/dev/null 2>&1; then
  nv-fabricmanager --version | sed 's/.*version is *//'
  systemctl is-active nvidia-fabricmanager.service 2>/dev/null || true
else
  echo 'nv-fabricmanager not installed'
fi

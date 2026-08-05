#!/bin/bash
# banner: ########INFO: Check IMEX nodes_config (informational, does not drain -- per-rack. Expected: file exist on GBXX)
# informational: yes
# Per-rack by design, so it is recorded and never drains. See
# docs/reference/health-checks.md#informational-checks.

if [ "$(uname -m)" == aarch64 ]; then
  md5sum /etc/nvidia-imex/nodes_config.cfg 2>/dev/null || true
fi

#!/bin/bash
# banner: ########INFO: Check IMEX nodes_config (informational, does not drain -- per-rack. Expected: file exist on GBXX)
# informational: yes
#
# INFORMATIONAL -- recorded, never drains. nodes_config.cfg lists the rack's
# own IMEX domain members, so its checksum is per-rack: every rack but the
# baseline node's differs by design.

if [ "$(uname -m)" == aarch64 ]; then
  md5sum /etc/nvidia-imex/nodes_config.cfg 2>/dev/null || true
fi

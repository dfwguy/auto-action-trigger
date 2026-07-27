#!/bin/bash
# banner: ########INFO: Check IMEX connection status (informational, does not drain -- per-rack and time-varying. Expected: Node be in READY, all nodes connected and Domain UP on GBXX)
# informational: yes
#
# INFORMATIONAL -- recorded, never drains. This is the live domain membership
# matrix, which is per-rack and also changes every time a node in the rack goes
# down: a baseline taken today is stale the next time one powers off. Node-local
# IMEX health is still enforced by imex-service and imex-readiness above.

if [ "$(uname -m)" == aarch64 ]; then
  nvidia-imex-ctl -N 2>&1 \
    | awk '/Nodes:/,/Domain state:/{print $0}' \
    | sed -e 's:\*: :g' -e 's:-::g' | tr -s ' '
fi

#!/bin/bash
# banner: ########INFO: Check IMEX connection status (informational, does not drain -- per-rack and time-varying. Expected: Node be in READY, all nodes connected and Domain UP on GBXX)
# informational: yes
#
# Recorded, never drains: no stable baseline exists. See
# docs/reference/health-checks.md#informational-checks.

if [ "$(uname -m)" == aarch64 ]; then
  nvidia-imex-ctl -N 2>&1 \
    | awk '/Nodes:/,/Domain state:/{print $0}' \
    | sed -e 's:\*: :g' -e 's:-::g' | tr -s ' '
fi

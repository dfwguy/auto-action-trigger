#!/bin/bash
# banner: ########INFO: Check CUUID (informational, does not drain -- per-rack. Expected: For GBXX, all nodes in the same rack have the same CUUID)
# informational: yes
#
# ClusterUUID is per-rack, so it cannot match one cluster-wide baseline.
# See docs/reference/health-checks.md#informational-checks.

nvidia-smi -q | grep -E 'Bus Id|CliqueId|ClusterUUID'

#!/bin/bash
# banner: ########INFO: Check CUUID (informational, does not drain -- per-rack. Expected: For GBXX, all nodes in the same rack have the same CUUID)
# informational: yes
#
# INFORMATIONAL -- recorded, never drains. The ClusterUUID is per-rack, as the
# header below has always said, so it cannot match a single cluster-wide
# baseline: every node outside the baseline node's rack differs by design. A
# genuinely miscabled node is caught by the benchmarks failing instead.

nvidia-smi -q | grep -E 'Bus Id|CliqueId|ClusterUUID'

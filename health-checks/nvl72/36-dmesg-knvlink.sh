#!/bin/bash
# banner: ########INFO: Check dmesg - knvlinkDiscoverPostRxDetLinks (Expected: No knvlinkDiscoverPostRxDetLinks)

sudo -n dmesg | grep "NVRM: knvlinkDiscoverPostRxDetLinks" | wc -l

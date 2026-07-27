#!/bin/bash
# banner: ########INFO: Check dmesg - knvlinkDiscoverPostRxDetLinks (Expected: No knvlinkDiscoverPostRxDetLinks)

dmesg | grep "NVRM: knvlinkDiscoverPostRxDetLinks" | wc -l

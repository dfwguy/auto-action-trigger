#!/bin/bash
# banner: ########INFO: Check PCIe ACS (Expected: All same brand nodes the same)

lspci -vvv | grep 'ACSCtl:.*SrcValid-' | wc -l

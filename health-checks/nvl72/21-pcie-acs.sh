#!/bin/bash
# banner: ########INFO: Check PCIe ACS (Expected: All same brand nodes the same)

sudo -n lspci -vvv | grep 'ACSCtl:.*SrcValid-' | wc -l

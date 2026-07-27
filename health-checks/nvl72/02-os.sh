#!/bin/bash
# banner: ########INFO: Check OS

uname -r
df -Th | grep /cm/node-installer &>/dev/null || echo 'OS is READY'

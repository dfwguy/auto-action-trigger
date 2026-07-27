#!/bin/bash
# banner: ########INFO: Check Kernel Parm

uname -r
cat /proc/cmdline | tr ' ' '\n' | grep -v -E 'ip=|BOOT' | sort | paste -s -d' '

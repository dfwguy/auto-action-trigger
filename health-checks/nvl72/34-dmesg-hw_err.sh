#!/bin/bash
# banner: ########INFO: Check dmesg - Hardware Error (Expected: No Hardware Error)

sudo -n dmesg | grep "Hardware Error" | wc -l

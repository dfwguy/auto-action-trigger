#!/bin/bash
# banner: ########INFO: Check dmesg - Hardware Error (Expected: No Hardware Error)

dmesg | grep "Hardware Error" | wc -l

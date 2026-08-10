#!/bin/bash
# banner: ########INFO: Check dmesg - Call trace (Expected: No Call trace)

sudo -n dmesg | grep -i "Call trace" | wc -l

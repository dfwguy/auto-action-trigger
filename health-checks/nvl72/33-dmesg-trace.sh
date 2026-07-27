#!/bin/bash
# banner: ########INFO: Check dmesg - Call trace (Expected: No Call trace)

dmesg | grep -i "Call trace" | wc -l

#!/bin/bash
# banner: ########INFO: Check dmesg - NV_ERR (Expected: No NV_ERR_*)

dmesg | grep -o "NV_ERR_[^]]*" | sort | uniq

#!/bin/bash
# banner: ########INFO: Check CPU

lscpu | awk '/Architecture:/,/L3 cache:/{print $0}' | grep -E -v 'GHz|MHz|BogoMIPS|Flags:|cache:'

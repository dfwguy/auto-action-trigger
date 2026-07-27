#!/bin/bash
# banner: ########INFO: Check BIOS

grep -r . /sys/class/dmi/id/bios_* 2>/dev/null | cut -d'/' -f6- | sort | paste -s -d','

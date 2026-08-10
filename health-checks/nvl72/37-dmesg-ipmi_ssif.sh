#!/bin/bash
# banner: ########INFO: Check dmesg - ipmi_ssif (Expected: No ipmi_ssif Not present errors)

if sudo -n ipmitool mc info &>/dev/null; then
  echo "ipmitool mc info OK"
else
  sudo -n dmesg --since "8 hour ago" | grep "ipmi_ssif.*i2c-.*Not present" | wc -l
fi

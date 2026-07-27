#!/bin/bash
# banner: ########INFO: Check dmesg - Xid (Expected: No Xid)
# reason-detail: yes

dmesg | grep -E -o 'Xid ([^)].*): [0-9]+,' \
  | tr -d ',' \
  | awk '{print $1":"$NF}' \
  | sort | uniq | paste -s -d','

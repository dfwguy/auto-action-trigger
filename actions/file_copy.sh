#!/bin/bash
#

[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

#sleep 60

rsync -r /home/cmods/bringup/containers/ /tmp/containers/

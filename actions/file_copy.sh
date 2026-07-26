#!/bin/bash
#
# Populate the node-local container cache in /tmp/containers/ from the shared
# copy in /home/cmods/bringup/containers/. Every job prefers the /tmp copy, so
# a benchmark start reads its image off local disk instead of pulling a
# multi-gigabyte squashfs over NFS on every run.
#
# Runs on each BCM monitoring cycle. -a matters: with plain -r the destination
# mtimes are the copy time, so rsync's size+mtime quick check never matches and
# every cycle re-transfers the whole directory -- exactly the NFS traffic this
# is meant to avoid. With -a, an unchanged image transfers once.

[[ "$CMD_CATEGORY" == "spcx-hosts" ]] || exit 0

#sleep 60

src=/home/cmods/bringup/containers
[[ -d "$src" ]] || exit 0

mkdir -p /tmp/containers
rsync -a --partial "$src/" /tmp/containers/

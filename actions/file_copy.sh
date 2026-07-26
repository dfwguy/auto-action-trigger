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
#
# Every precondition below is a silent exit 0, not an error. This is a cache
# warmer: nothing depends on it having run, because each job falls back to the
# NFS path when its image is not in /tmp yet. A node with no images built yet,
# no rsync installed, or NFS not mounted should look no different to BCM than
# one with nothing to do -- otherwise the action logs a failure on every
# monitoring cycle, on every node, forever, and the real failures get lost in
# it. Genuine copy problems are left to surface as a job start reading from
# NFS, which still works.

src=/home/cmods/bringup/containers
dst=/tmp/containers

## Category gate. node_health.sh and launch_job.sh both have this line
## commented out, so leaving it active here would make this the only action
## that no-ops at a site not using BCM categories. Kept as an unset-safe test:
## it now runs everywhere, and gates only if the variable is actually set to
## something else.
if [[ -n "${CMD_CATEGORY:-}" && "$CMD_CATEGORY" != "spcx-hosts" ]]; then
    exit 0
fi

#sleep 60

## Nothing to copy from -- images not built yet, or NFS not mounted here.
[[ -d "$src" ]] || exit 0

## An empty containers/ is the normal state before the first build. Copying it
## would be a no-op anyway; skipping keeps rsync out of the process table on
## every cycle across the whole cluster.
compgen -G "$src"/*.sqsh >/dev/null 2>&1 || exit 0

command -v rsync >/dev/null 2>&1 || exit 0

mkdir -p "$dst" 2>/dev/null || exit 0

## --partial so a run cut short by the action timeout resumes next cycle
## instead of starting the multi-gigabyte transfer again.
rsync -a --partial "$src/" "$dst/" >/dev/null 2>&1

exit 0

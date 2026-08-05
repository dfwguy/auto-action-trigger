#!/bin/bash
#
# Warm the node-local container cache /tmp/containers/ from the shared NFS
# copy. See docs/explanation/containers.md#how-the-caching-works.
#
# Every precondition below is a silent exit 0: jobs fall back to the NFS path,
# so nothing depends on this having run, and an error per node per cycle would
# bury the real ones.

home=/home/cmods/bringup
src="$home/containers"
dst=/tmp/containers

## Read only for PAUSE_CONTAINER_COPY, so a missing settings.sh is not fatal
## here as it is in the other two actions: the worst it costs is a cache warm
## during a pause.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"

## Only new copies are stopped; a detached rsync finishes.
## See docs/reference/settings.md#pause-switches.
if declare -F setting_enabled >/dev/null && setting_enabled "${PAUSE_CONTAINER_COPY:-no}"; then
    exit 0
fi

#sleep 60

## Nothing to copy from -- images not built yet, or NFS not mounted here.
[[ -d "$src" ]] || exit 0

## Empty containers/ is the normal pre-build state; skip to keep rsync out of
## the process table on every cycle, clusterwide.
compgen -G "$src"/*.sqsh >/dev/null 2>&1 || exit 0

command -v rsync >/dev/null 2>&1 || exit 0

mkdir -p "$dst" 2>/dev/null || exit 0

## The first multi-gigabyte sync does not fit in BCM's 2m action timeout, so it
## is detached and this script returns immediately; flock stops the every-cycle
## duringactions trigger from stacking rsyncs on the same destination.
lock=/tmp/.file_copy.lock

if [[ -z "${FILE_COPY_DETACHED:-}" ]]; then
    ## Via bash, not "$0" directly: a checkout that lost the exec bit would
    ## fail here silently and never copy anything.
    if command -v setsid >/dev/null 2>&1; then
        FILE_COPY_DETACHED=1 setsid nohup bash "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
    ## No setsid: copy inline, cut off at the action timeout, resume next cycle.
fi

if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" 2>/dev/null || exit 0
    flock -n 9 || exit 0          # a copy from an earlier cycle is still running
fi

## -a not -r, or every cycle re-transfers everything; --partial so a killed
## copy resumes. See docs/explanation/containers.md#how-the-caching-works.
rsync -a --partial "$src/" "$dst/" >/dev/null 2>&1

exit 0

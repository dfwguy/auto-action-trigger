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

home=/home/cmods/bringup
src="$home/containers"
dst=/tmp/containers

## Settings are read for one switch, PAUSE_CONTAINER_COPY, and a missing
## settings.sh is not fatal here -- unlike the other two actions, which refuse
## to run without one. Nothing is judged or drained from this script, so the
## worst a missing file costs is a cache warm that keeps happening during a
## pause. Refusing to copy would be the more surprising of the two.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"

## An rsync detached by an earlier cycle is left to finish -- it is NFS reads
## into a local cache, holds no node and blocks no job, and killing it mid-copy
## just means transferring those bytes again later. What the pause stops is
## starting another one.
if declare -F setting_enabled >/dev/null && setting_enabled "${PAUSE_CONTAINER_COPY:-no}"; then
    exit 0
fi

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

## BCM caps an action timeout at 2m and kills whatever is still running. The
## first sync of an image is multi-gigabyte over NFS and does not fit in that,
## so the copy is detached with setsid and this script returns immediately.
## The action always completes well inside its timeout; the transfer outlives
## it. --partial means even a copy killed for some other reason resumes rather
## than restarting.
##
## flock keeps the monitoring cycles from stacking: the trigger is
## duringactions, so it fires again every cycle while the first copy is still
## running, and without the lock each one would spawn another rsync against
## the same destination.
lock=/tmp/.file_copy.lock

if [[ -z "${FILE_COPY_DETACHED:-}" ]]; then
    ## Re-exec through bash rather than running "$0" directly: the latter needs
    ## the exec bit, and a checkout that lost it would fail here silently and
    ## never copy anything.
    if command -v setsid >/dev/null 2>&1; then
        FILE_COPY_DETACHED=1 setsid nohup bash "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
    ## No setsid: fall through and copy inline. Large images will be cut off
    ## at the action timeout and resume on later cycles instead.
fi

if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" 2>/dev/null || exit 0
    flock -n 9 || exit 0          # a copy from an earlier cycle is still running
fi

rsync -a --partial "$src/" "$dst/" >/dev/null 2>&1

exit 0

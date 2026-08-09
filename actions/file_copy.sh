#!/bin/bash
#
# Warm the node-local container cache /tmp/containers/ from the shared copy.
# See docs/explanation/containers.md#how-the-caching-works.
#
# Every precondition below ends the run, and every one of them says so in
# results/<node>/copy.log. Jobs fall back to the shared path, so nothing depends
# on this having run -- but "the images never arrived" and "the images are not
# built yet" are the same silence from outside, which is the thing this tree is
# written against. See docs/reference/trace-lines.md#the-container-copy-trace.

## Located from this file, like the other two steps.
## See docs/reference/layout.md#runtime-paths.
home="${FILE_COPY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
dst=/tmp/containers

## Read for PAUSE_CONTAINER_COPY and CONTAINER_DIR, but a missing settings.sh is
## not fatal here as it is in the other two steps: it costs a cache warm.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"
src="${CONTAINER_DIR:-$home/containers}"

## Beside health.log and trigger.log rather than in agent.log, which belongs to
## the agent: the detached copy below outlives the cycle that started it and
## writes here after the agent has moved on.
logs="$home/results/$HOSTNAME"
tracelog="$logs/copy.log"
trace() {
    mkdir -p "$logs" 2>/dev/null
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$tracelog" 2>/dev/null
    [[ -t 1 ]] && printf '%s\n' "$*"
    return 0
}
if [[ -f "$tracelog" ]] && [[ "$(stat -c %s "$tracelog" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
    tail -2000 "$tracelog" > "$tracelog.tmp" && mv "$tracelog.tmp" "$tracelog"
fi

## Only new copies are stopped; a detached rsync finishes.
## See docs/reference/settings.md#pause-switches.
if declare -F setting_enabled >/dev/null && setting_enabled "${PAUSE_CONTAINER_COPY:-no}"; then
    trace "EXIT: PAUSE_CONTAINER_COPY=$PAUSE_CONTAINER_COPY in ${SETTINGS_FILE:-<none>} -- no new copy started; one already running finishes"
    exit 0
fi

## Nothing to copy from -- images not built yet, or the share not mounted here.
if [[ ! -d "$src" ]]; then
    trace "EXIT: $src does not exist here (CONTAINER_DIR from ${SETTINGS_FILE:-<none>}) -- nothing to copy from. Not mounted on this node, or the images have not been built."
    exit 0
fi

## Empty containers/ is the normal pre-build state.
if ! compgen -G "$src/*.sqsh" >/dev/null 2>&1; then
    trace "EXIT: no *.sqsh in $src -- nothing to copy yet. This is the normal state until build_containers.sh has run."
    exit 0
fi

command -v rsync >/dev/null 2>&1 || { trace "EXIT: rsync is not installed here -- jobs will read the image over the share instead"; exit 0; }
mkdir -p "$dst" 2>/dev/null || { trace "EXIT: cannot create $dst as $(id -un)"; exit 0; }

## The first multi-gigabyte sync outlives the agent's cycle, so it is detached
## and this script returns immediately -- otherwise it holds the agent's lock
## across cycles and nothing else on the node runs. flock stops one cycle's copy
## being stacked on the next. See docs/explanation/containers.md#how-the-caching-works.
lock=/tmp/.file_copy.lock

if [[ -z "${FILE_COPY_DETACHED:-}" ]]; then
    ## Via bash, not "$0" directly: a checkout that lost the exec bit would
    ## fail here silently and never copy anything.
    if command -v setsid >/dev/null 2>&1; then
        FILE_COPY_DETACHED=1 setsid nohup bash "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
    ## No setsid: copy inline, cut off with the cycle, resume next time.
    trace "setsid is not installed -- copying inline, which holds this cycle until it finishes"
fi

if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock" 2>/dev/null || exit 0
    flock -n 9 || exit 0          # a copy from an earlier cycle is still running
fi

## Counted rather than assumed: "rsync ran" and "the images are here" are
## different facts, and only the second one lets a job start off local disk.
## Quoted, so compgen does the globbing: unquoted, the shell expands it first
## and compgen only confirms the first match.
have_before=$(compgen -G "$dst/*.sqsh" 2>/dev/null | wc -l)
want=$(compgen -G "$src/*.sqsh" 2>/dev/null | wc -l)
[[ "$have_before" -lt "$want" ]] && trace "copying: $have_before of $want image(s) here, from $src"

## -a not -r, or every cycle re-transfers everything; --partial so a killed
## copy resumes. See docs/explanation/containers.md#how-the-caching-works.
out=$(rsync -a --partial "$src/" "$dst/" 2>&1); rc=$?
have=$(compgen -G "$dst/*.sqsh" 2>/dev/null | wc -l)

if [[ "$rc" -ne 0 ]]; then
    trace "COPY FAILED (rsync exit $rc): ${out//$'\n'/ } -- $have of $want image(s) here; jobs read the share instead"
elif [[ "$have_before" -lt "$want" ]]; then
    trace "copied: $have of $want image(s) now in $dst"
fi

exit 0

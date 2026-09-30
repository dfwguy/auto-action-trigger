#!/bin/bash
#
# Warm the node-local container cache (NODE_CONTAINER_DIR) from the shared copy.
# See docs/explanation/containers.md#how-the-caching-works.
#
# Everything in CONTAINER_DIR, with no opinion about which images matter -- what
# is in there is what build_containers.sh was asked to build.
#
# Every precondition below ends the run, and every one of them says so in
# results/<node>/copy.log. Jobs fall back to the shared path, so nothing depends
# on this having run -- but "the images never arrived" and "the images are not
# built yet" are the same silence from outside, which is the thing this tree is
# written against. See docs/reference/trace-lines.md#the-container-copy-trace.

# Usage: file_copy.sh [--explain] [--verbose|--quiet]
#
#   --explain, -n   dry run: itemize what rsync would copy, change nothing
#   --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
#   --quiet,   -q   never mirror the trace to stdout

## Located from this file, like the other two steps.
## See docs/reference/layout.md#runtime-paths.
home="${FILE_COPY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

## Read for the PAUSE/CONTAINER settings, but a missing settings.sh is not
## fatal here as it is in the other two steps: it costs a cache warm.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"
src="${CONTAINER_DIR:-/cluster/bringup-data/containers}"
dst="${NODE_CONTAINER_DIR:-/opt/containers}"

EXPLAIN=0
VERBOSE=0; [[ -t 1 ]] && VERBOSE=1
usage() {
    cat <<USAGE
Usage: file_copy.sh [--explain] [--verbose|--quiet]

  --explain, -n   dry run: itemize what rsync would copy, change nothing
  --verbose, -v   mirror the trace to stdout (default when stdout is a tty)
  --quiet,   -q   never mirror the trace to stdout

Copies everything under CONTAINER_DIR into NODE_CONTAINER_DIR. With no
arguments -- how the node agent normally invokes it -- the copy is detached and
continues in its own transient service.
USAGE
}
for arg in "$@"; do
    case "$arg" in
        --explain|-n|--dry-run) EXPLAIN=1 ;;
        --verbose|-v)           VERBOSE=1 ;;
        --quiet|-q)             VERBOSE=0 ;;
        -h|--help)              usage; exit 0 ;;
        *)  echo "ERROR: unrecognised argument '$arg' -- nothing was copied." >&2
            usage >&2
            exit 2 ;;
    esac
done

## Beside health.log and trigger.log rather than in agent.log, which belongs to
## the agent: the detached copy below outlives the cycle that started it and
## writes here after the agent has moved on.
logs="$RESULTS_DIR/$HOSTNAME"
tracelog="$logs/copy.log"
trace() {
    if [[ "$EXPLAIN" -eq 0 ]]; then
        mkdir -p "$logs" 2>/dev/null
        printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$tracelog" 2>/dev/null
    fi
    [[ "$EXPLAIN" -eq 1 || "$VERBOSE" -eq 1 ]] && printf '%s\n' "$*"
    return 0
}
## RUN_CONTAINER_COPY replaced PAUSE_CONTAINER_COPY. See
## docs/reference/settings.md#run-switches.
declare -F old_setting_present >/dev/null && old_setting_present PAUSE_CONTAINER_COPY &&
    trace "WARNING: SETTINGS still sets PAUSE_CONTAINER_COPY -- this key was renamed to RUN_CONTAINER_COPY (RUN_CONTAINER_COPY=no is the equivalent). PAUSE_CONTAINER_COPY is no longer read. Update SETTINGS."

## Only new copies are stopped; a detached rsync finishes.
## See docs/reference/settings.md#run-switches.
if declare -F setting_disabled >/dev/null && setting_disabled "${RUN_CONTAINER_COPY:-yes}"; then
    ## RUN_CONTAINER_COPY is the switch; this file does not disable anything.
    ## It only remembers that this disabled period was already reported, so the
    ## two-minute fleet cycle does not append the same line to NFS every time.
    ## XDG_RUNTIME_DIR is node-local and normally cleared when the node reboots.
    disabled_log_marker="${XDG_RUNTIME_DIR:-/tmp}/.bringup-file-copy.disabled-state-logged"
    if [[ "$EXPLAIN" -eq 1 ]]; then
        trace "NOTE: RUN_CONTAINER_COPY=$RUN_CONTAINER_COPY in ${SETTINGS_FILE:-<none>} -- a real run starts no new copy; previewing what would be copied if enabled"
    elif [[ ! -e "$disabled_log_marker" ]]; then
        : > "$disabled_log_marker" 2>/dev/null || true
        trace "EXIT: RUN_CONTAINER_COPY=$RUN_CONTAINER_COPY in ${SETTINGS_FILE:-<none>} -- no new copy started; one already running finishes"
    fi
    [[ "$EXPLAIN" -eq 1 ]] || exit 0
fi
## The setting is read on every cycle. When it is enabled again, forget the old
## log suppression state so a later disabled period gets one new trace line.
[[ "$EXPLAIN" -eq 1 ]] || rm -f "${XDG_RUNTIME_DIR:-/tmp}/.bringup-file-copy.disabled-state-logged" 2>/dev/null || true

## Rotation stays below the disabled fast path so a no-op cycle does not even
## stat the shared trace file.
if [[ "$EXPLAIN" -eq 0 && -f "$tracelog" ]] && [[ "$(stat -c %s "$tracelog" 2>/dev/null || echo 0)" -gt 1000000 ]]; then
    tail -2000 "$tracelog" > "$tracelog.tmp" && mv "$tracelog.tmp" "$tracelog"
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

## Ask the same rsync invocation what it would change. This is above mkdir,
## detachment and the copy lock: an explanation must not create even an empty
## destination, start a transient unit or contend with a real copy. rsync's
## itemized output includes files other than *.sqsh because the real service
## copies the entire source directory once at least one image exists there.
if [[ "$EXPLAIN" -eq 1 ]]; then
    trace "--explain: $src/ -> $dst/"
    out=$(rsync -a --partial --dry-run --itemize-changes "$src/" "$dst/" 2>&1); rc=$?
    if [[ "$rc" -ne 0 ]]; then
        trace "WOULD COPY FAILED (rsync exit $rc): ${out//$'\n'/ }"
        exit "$rc"
    elif [[ -n "$out" ]]; then
        printf '%s\n' "$out"
    else
        trace "up to date: rsync would copy nothing"
    fi
    exit 0
fi

mkdir -p "$dst" 2>/dev/null || { trace "EXIT: cannot create $dst as $(id -un)"; exit 0; }

## ── The copy is its own unit, not a child of this one ─────────────────────
##
## A first sync is several gigabytes and cannot finish inside a cycle, so it has
## to outlive the cycle -- and a background child does not. systemd cleans out
## the unit's cgroup when the cycle ends, so a `setsid ... &` child is killed
## with whatever time happened to be left, which is anything from a few
## milliseconds to a few seconds depending on what the other steps did. Nothing
## about that is a design; it is a race the copy usually loses.
##
## systemd-run puts the copy in a transient unit of its own, which is not this
## unit's cgroup and is not cleaned up with it. It runs to completion, once,
## however long it takes. --collect removes the unit when it finishes.
## See docs/explanation/containers.md#the-copy-is-its-own-unit.
lock=/tmp/.file_copy.lock

if [[ -z "${FILE_COPY_DETACHED:-}" ]]; then
    if [[ -n "${XDG_RUNTIME_DIR:-}${INVOCATION_ID:-}" ]] && command -v systemd-run >/dev/null 2>&1 &&
       systemd-run --user --collect --quiet --unit=bringup-copy \
                   --description="Bring-up container image copy" \
                   --setenv=FILE_COPY_DETACHED=1 \
                   bash "$0" 2>/dev/null; then
        exit 0
    fi
    ## Already running from an earlier cycle: systemd-run refuses a unit name
    ## that is active, which is the same answer the flock below gives.
    if systemctl --user is-active --quiet bringup-copy.service 2>/dev/null; then
        exit 0
    fi
    ## No systemd-run, or no user manager to run it in -- a hand-run from a
    ## plain shell. setsid is enough there: nothing is going to clean up a
    ## cgroup this process is not in.
    if command -v setsid >/dev/null 2>&1; then
        FILE_COPY_DETACHED=1 setsid nohup bash "$0" </dev/null >/dev/null 2>&1 &
        exit 0
    fi
    trace "neither systemd-run nor setsid is available -- copying inline, which holds this cycle until it finishes"
fi

if command -v flock >/dev/null 2>&1; then
    ## The braces matter: `exec 9>file 2>/dev/null` opens left to right, so the
    ## failure is reported before stderr is redirected and lands in the journal.
    ## Same trap as the trace writability check in launch_job.sh.
    if ! { exec 9>"$lock"; } 2>/dev/null; then
        trace "EXIT: cannot open $lock as $(id -un) -- $(stat -c 'owned by %U' "$lock" 2>/dev/null || echo '/tmp is not writable here'). No copy was started. Fix: sudo rm -f $lock (on this node)"
        exit 0
    fi
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

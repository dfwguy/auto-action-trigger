#!/bin/bash
#
# Usage: kill-jobs.sh [-n] [-p] [node-pattern ...]
#
# Cancels every job this framework has out, and only those: the ones submitted
# as bringup-<node> and burnin-<node>. Another team's job sharing a node is
# matched by neither name and is never touched.
#
#   pattern  optional node filter, repeatable, with the same rules as
#            status-check.sh: a bare string matches every node whose name starts
#            with it, so a rack prefix covers the whole rack, and a pattern
#            holding a glob character is honored as written.
#
#              kill-jobs.sh                          every node
#              kill-jobs.sh ink50-dh01-i01           that node and anything under it
#              kill-jobs.sh 'dh01-rack0[12]*' dh02   two racks and a prefix
#
#            A pattern matching nothing cancels nothing and says so. It is not
#            an error: an empty queue is the state this script exists to reach.
#
#   -p, --pause
#            also set PAUSE_JOBS=yes in SETTINGS, before cancelling anything.
#            Without it the next agent cycle queues the work straight back
#            and this was a stall rather than a stop.
#
#            The pause is fleet-wide however narrow the patterns are -- SETTINGS
#            is one file, NFS-exported to every node -- and the run says so.
#            SETTINGS is created from SETTINGS.default if the site has none;
#            SETTINGS.default itself is never edited, being the shipped copy a
#            tarball drop overwrites. Lift the pause by hand with PAUSE_JOBS=no.
#
#   -n, --dry-run
#            list what would be cancelled and stop: nothing is scancelled and
#            SETTINGS is not written, including with -p. The queue is still
#            read, so this is the real list of jobs and not a guess -- check a
#            fleet-wide pattern with it before pasting the run that means it.
#
# Safe to run from any directory, and safe to run twice.
#
# What a cancelled job leaves behind, and why none of it needs cleaning up by
# hand, is in docs/how-to/pause-and-resume.md#emptying-the-queue-now.
#
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

## Cancelling needs Slurm and nothing else, so the tree is located separately
## and only --pause requires finding it. This script gets pasted into other
## teams' checkouts. See docs/how-to/pause-and-resume.md#emptying-the-queue-now.
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
home=""
for cand in "$self_dir" "${BRINGUP_HOME:-}"; do
    [[ -n "$cand" ]] || continue
    [[ -f "$cand/SETTINGS" || -f "$cand/SETTINGS.default" ]] && { home="$cand"; break; }
done

pause=0
dryrun=0
patterns=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--pause)   pause=1; shift ;;
        -n|--dry-run) dryrun=1; shift ;;
        -h|--help)
            sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 1 ;;
        *)  patterns+=("$1"); shift ;;
    esac
done

## The slurm tools live behind a module and are absent from a fresh remote shell.
if ! command -v squeue >/dev/null 2>&1 && [[ -r /etc/profile.d/modules.sh ]]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/modules.sh >/dev/null 2>&1
    command -v module >/dev/null 2>&1 && module load slurm >/dev/null 2>&1
fi
for tool in squeue scancel; do
    command -v "$tool" >/dev/null 2>&1 && continue
    echo "ERROR: $tool is not on PATH even after 'module load slurm' -- run this on a" >&2
    echo "       head or compute node with the slurm module available." >&2
    exit 1
done

for i in "${!patterns[@]}"; do
    [[ "${patterns[i]}" == *[*?[]* ]] || patterns[i]="${patterns[i]}*"
done

node_selected() {
    [[ "${#patterns[@]}" -eq 0 ]] && return 0
    local p
    for p in "${patterns[@]}"; do
        ## SC2053: the glob match is the point; quoting makes it a literal compare.
        # shellcheck disable=SC2053
        [[ "$1" == $p ]] && return 0
    done
    return 1
}

## Before the cancel, not after: the agent cycles every couple of minutes, and
## a cycle landing in between would resubmit what this is clearing.
pause_failed=""
if [[ "$pause" -eq 1 && "$dryrun" -eq 1 ]]; then
    if [[ -n "$home" ]]; then
        echo "WOULD SET PAUSE_JOBS=yes in $home/SETTINGS$([[ -f "$home/SETTINGS" ]] || printf ', created from SETTINGS.default')"
    else
        echo "WOULD NOT PAUSE: no SETTINGS or SETTINGS.default beside $self_dir${BRINGUP_HOME:+ or at $BRINGUP_HOME}"
    fi
elif [[ "$pause" -eq 1 ]]; then
    if [[ -z "$home" ]]; then
        pause_failed="no SETTINGS or SETTINGS.default beside $self_dir${BRINGUP_HOME:+ or at $BRINGUP_HOME} -- set BRINGUP_HOME to the deployed tree"
    else
        settings="$home/SETTINGS"
        if [[ ! -f "$settings" ]]; then
            if cp "$home/SETTINGS.default" "$settings"; then
                echo "Created $settings from SETTINGS.default"
            else
                pause_failed="could not create $settings"
            fi
        fi
        if [[ -z "$pause_failed" ]]; then
            if grep -qE '^[[:space:]]*PAUSE_JOBS=' "$settings"; then
                sed -i -E 's/^[[:space:]]*PAUSE_JOBS=.*/PAUSE_JOBS=yes/' "$settings"
            else
                printf 'PAUSE_JOBS=yes\n' >> "$settings"
            fi
            ## Read back rather than trusted: a sed that matched nothing exits 0.
            if grep -qE '^PAUSE_JOBS=yes[[:space:]]*$' "$settings"; then
                echo "PAUSE_JOBS=yes in $settings -- fleet-wide, on the next agent cycle."
                [[ "${#patterns[@]}" -gt 0 ]] &&
                    echo "NOTE: the pause is not narrowed by the pattern; it stops the sweep on every node."
            else
                pause_failed="$settings still does not read PAUSE_JOBS=yes"
            fi
        fi
    fi
    [[ -n "$pause_failed" ]] && echo "WARNING: not paused: $pause_failed" >&2
fi

## One squeue call for the cluster. The node is the job name's suffix, which is
## how it was submitted. See docs/explanation/sequencing.md#one-job-at-a-time.
##
## Read into a variable first: a controller that will not answer prints nothing,
## which is indistinguishable from an empty queue at the wrong moment.
if ! queue=$(squeue -h -o '%i|%j|%T' 2>&1); then
    echo "ERROR: squeue failed, so the queue was never read and nothing was cancelled:" >&2
    echo "       ${queue:-<no output>}" >&2
    exit 1
fi

ids=()
listing=""
while IFS='|' read -r id name state; do
    case "$name" in
        bringup-*) node=${name#bringup-} ;;
        burnin-*)  node=${name#burnin-} ;;
        *)         continue ;;
    esac
    node_selected "$node" || continue
    ids+=("$id")
    listing+=$(printf '  %-14s %-32s %s\n' "$id" "$name" "$state")$'\n'
done <<< "$queue"

rc=0
if [[ "${#ids[@]}" -eq 0 ]]; then
    echo "Nothing of ours is queued${patterns:+ under ${patterns[*]}} -- nothing cancelled."
elif [[ "$dryrun" -eq 1 ]]; then
    printf 'WOULD CANCEL %d job(s):\n%s' "${#ids[@]}" "$listing"
else
    printf 'Cancelling %d job(s):\n%s' "${#ids[@]}" "$listing"
    out=$(scancel "${ids[@]}" 2>&1) || rc=1
    if [[ "$rc" -ne 0 || -n "$out" ]]; then
        ## scancel reports a refused kill on stdout and can still exit 0, so the
        ## output is the report, not the status.
        echo "WARNING: scancel said: $out" >&2
        echo "         Jobs run as the framework's JOB_USER; cancelling them needs that" >&2
        echo "         account or root. Re-check with: squeue -o '%i %j %T' | grep -E 'bringup-|burnin-'" >&2
        rc=1
    fi
fi

## Silence is the enemy: a stop that only lasts an hour has to say so, and a run
## that changed nothing must not read like one that did.
if [[ "$dryrun" -eq 1 ]]; then
    echo "Dry run: nothing was cancelled and nothing was written. Drop -n to act."
elif [[ "$pause" -ne 1 ]]; then
    echo "Not paused: the sweep resubmits on its next cycle. Re-run with -p to stop it."
fi

[[ -n "$pause_failed" ]] && exit 1
exit "$rc"

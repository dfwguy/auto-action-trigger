#!/bin/bash
#
# Usage: trigger-log.sh [-w hours] [-s minutes] [-t lines] [node-pattern]
#
# Answers "why is nothing running?" from the written record rather than from
# the configuration: what the two node-side actions wrote at
# results/<node>/trigger.log and health.log, summarized fleet-wide. Run this
# one FIRST; trigger-debug.sh is for when the traces turn out to be stale.
#
#   Logs stale or missing  -> nothing is running the script. trigger-debug.sh.
#   Logs fresh, no submits -> the script is running and every gate is closed.
#                             The reason is in section 2, already written down.
#
# That distinction is section 1, and it is why this leads with timestamps
# instead of contents: a fleet whose logs all stopped an hour ago is a BCM
# problem that no amount of reading decisions will show, and a fleet with
# fresh logs and zero submissions is a gate problem with BCM working fine.
#
#   -w, --window <hours>   how far back to scan for events. Default 24.
#   -s, --stale <minutes>  a log older than this has stopped being written.
#                          Default 15 -- several BCM monitoring cycles, so a
#                          slow cycle or a node that just booted is not noise.
#   -t, --tail <lines>     lines of raw trace to print per node. Default 0
#                          (summary only); implied 20 when the pattern matches
#                          a single node, where a histogram of one is useless.
#   --include-excluded     read the hosts the reports leave out as well -- the
#                          head node. Their traces say why they were excluded.
#   pattern                node filter, same rules as status-check.sh: a bare
#                          string matches by prefix, globs are honored as
#                          written.
#
# Read-only. It submits nothing, drains nothing, changes nothing.
#
# The five sections it prints, and what each one rules out, are described in
# docs/how-to/diagnose-nothing-running.md.
#
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"      ## for BRINGUP_HOME, in the closing hint
results_dir="$home/results"
logs_dir="$home/logs"

window_hours=24
stale_minutes=15
tail_lines=-1          ## "not set": distinguishes an explicit -t 0 from no flag
include_excluded=0

args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--window)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a number of hours" >&2; exit 1; }
            window_hours="$2"; shift 2 ;;
        -s|--stale)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a number of minutes" >&2; exit 1; }
            stale_minutes="$2"; shift 2 ;;
        -t|--tail)
            [[ -n "$2" ]] || { echo "ERROR: $1 needs a number of lines" >&2; exit 1; }
            tail_lines="$2"; shift 2 ;;
        --include-excluded) include_excluded=1; shift ;;
        -h|--help)
            sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unknown option $1" >&2; exit 1 ;;
        *)  args+=("$1"); shift ;;
    esac
done

for n in "$window_hours" "$stale_minutes" "$tail_lines"; do
    [[ "$n" =~ ^-?[0-9]+$ ]] || { echo "ERROR: '$n' is not a number" >&2; exit 1; }
done

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

now=$(date +%s)
cutoff=$(date -d "@$(( now - window_hours * 3600 ))" '+%F %T' 2>/dev/null) || {
    echo "ERROR: this script needs GNU date" >&2; exit 1; }
stale_secs=$(( stale_minutes * 60 ))

problems=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  ** %s\n' "$*"; problems=$((problems + 1)); }
hdr()  { printf '\n=== %s ===\n' "$*"; }

##############################################################################
## Collect
##############################################################################

shopt -s nullglob
## $pattern is a glob, not a value: quoting it (or read -a) yields one literal
## element, and every loop below then reports the fleet as empty.
# shellcheck disable=SC2206
node_dirs=("$results_dir"/$pattern/)

## This is the tool for "why is nothing running?", so the excluded hosts are
## dropped by default but reachable: their trigger.log holds the answer.
## See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
if [[ "$include_excluded" -eq 0 ]]; then
    keep=(); excluded=()
    for node_dir in "${node_dirs[@]}"; do
        node=$(basename "$node_dir")
        if node_out_of_reporting "$results_dir" "$node"; then
            excluded+=("$node")
        else
            keep+=("$node_dir")
        fi
    done
    node_dirs=("${keep[@]}")
    [[ "${#excluded[@]}" -gt 0 ]] &&
        echo "NOTE: not compute nodes, skipped (--include-excluded to read them): ${excluded[*]}" >&2
fi

if [[ "${#node_dirs[@]}" -eq 0 ]]; then
    echo "ERROR: no node directories under $results_dir match '${args[0]:-*}'" >&2
    [[ -d "$results_dir" ]] || echo "       $results_dir does not exist -- the trigger has never run" >&2
    exit 1
fi

## One node and no explicit -t: show the trace, not a one-row summary.
if [[ "${#node_dirs[@]}" -eq 1 && "$tail_lines" -lt 0 ]]; then
    tail_lines=20
fi
[[ "$tail_lines" -lt 0 ]] && tail_lines=0

## Group key for a trace line: node names and numbers out, so one reason does
## not split into one group per node. See docs/how-to/diagnose-nothing-running.md.
normalize() {
    local msg="$1" node="$2"
    msg="${msg//$node/<node>}"
    sed -E 's/[0-9]+/N/g; s/N+/N/g' <<<"$msg"
}

declare -A last_reason_count last_reason_example
declare -A event_count event_example
missing_log=(); stale_log=(); empty_log=(); fresh=0
submits=0; submit_fail=0
newest_write=0; oldest_write=0

for node_dir in "${node_dirs[@]}"; do
    node=$(basename "$node_dir")
    log="$node_dir/trigger.log"

    if [[ ! -f "$log" ]]; then
        missing_log+=("$node")
        continue
    fi

    mtime=$(stat -c %Y "$log" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    if [[ "$age" -gt "$stale_secs" ]]; then
        stale_log+=("$node ${age}s")
    else
        fresh=$((fresh + 1))
    fi
    [[ "$mtime" -gt "$newest_write" ]] && newest_write="$mtime"
    [[ "$oldest_write" -eq 0 || "$mtime" -lt "$oldest_write" ]] && oldest_write="$mtime"

    ## One pass per log: last decision plus notable events in the window.
    ## `%F %T` timestamps compare chronologically as strings -- no date(1) per line.
    saw_decision=0
    while IFS=$'\t' read -r kind payload; do
        case "$kind" in
            last)
                saw_decision=1
                key=$(normalize "$payload" "$node")
                last_reason_count["$key"]=$(( ${last_reason_count["$key"]:-0} + 1 ))
                [[ -n "${last_reason_example["$key"]}" ]] || last_reason_example["$key"]="$node: $payload"
                ;;
            sub)  submits=$(( submits + payload )) ;;
            ev)
                key=$(normalize "$payload" "$node")
                event_count["$key"]=$(( ${event_count["$key"]:-0} + 1 ))
                [[ -n "${event_example["$key"]}" ]] || event_example["$key"]="$node: $payload"
                [[ "$payload" == "SUBMIT FAILED"* ]] && submit_fail=$((submit_fail + 1))
                ;;
        esac
    done < <(awk -v cut="$cutoff" '
        {
            ts = substr($0, 1, 19)
            msg = substr($0, 21)
            if (msg != "") last = msg
            if (ts < cut) next
            if (msg ~ /^submitted /)                      { n++; next }
            if (msg ~ /^(SUBMIT FAILED|WARNING|DRAIN|RECOVER)/ ||
                msg ~ /recover skipped: .* recovered /  ||
                msg ~ /verdict\.sh is missing/ ||
                msg ~ /not on PATH/ ||
                msg ~ /not a compute node|has no slurmd/) { print "ev\t" msg }
        }
        END {
            if (last != "") print "last\t" last
            print "sub\t" (n + 0)
        }
    ' "$log")
    ## A log with no trace lines: usually one trace() cannot write to, which
    ## fails silently by design. Untracked, it counts as fresh and section 1
    ## and 2 then disagree with no reason given.
    [[ "$saw_decision" -eq 1 ]] || empty_log+=("$node")
done

##############################################################################
hdr "1. Is the trigger firing? (${#node_dirs[@]} node dir(s), stale = no write in ${stale_minutes}m)"
##############################################################################

## Fleet-wide case first: if every log stopped, nothing below can be trusted.
if [[ "$fresh" -eq 0 && "${#stale_log[@]}" -gt 0 ]]; then
    bad "NO node has written a trigger.log in ${stale_minutes}m -- the sequencer is not running anywhere"
    note "the decisions in section 2 are stale; they are what the nodes last thought, not what is true now"
    note "this is a trigger-side failure, not a gate: run ./trigger-debug.sh"
elif [[ "${#stale_log[@]}" -gt 0 ]]; then
    bad "${#stale_log[@]} node(s) stale, $fresh fresh -- the trigger is firing, but not on these"
    printf '     %s\n' "${stale_log[@]:0:10}"
    [[ "${#stale_log[@]}" -gt 10 ]] && note "   ... and $(( ${#stale_log[@]} - 10 )) more"
else
    note "$fresh node(s) written within ${stale_minutes}m -- the sequencer is running"
fi

if [[ "${#missing_log[@]}" -gt 0 ]]; then
    bad "${#missing_log[@]} node dir(s) have no trigger.log at all -- the script has never run there"
    printf '     %s\n' "${missing_log[@]:0:10}"
    [[ "${#missing_log[@]}" -gt 10 ]] && note "   ... and $(( ${#missing_log[@]} - 10 )) more"
fi

if [[ "${#empty_log[@]}" -gt 0 ]]; then
    bad "${#empty_log[@]} node(s) have a trigger.log with no trace lines in it -- these are absent from section 2"
    note "an empty trace usually means the file is not writable by the user BCM runs the script as"
    printf '     %s\n' "${empty_log[@]:0:10}"
    [[ "${#empty_log[@]}" -gt 10 ]] && note "   ... and $(( ${#empty_log[@]} - 10 )) more"
fi

[[ "$newest_write" -gt 0 ]] && note "newest write $(date -d "@$newest_write" '+%F %T'), oldest $(date -d "@$oldest_write" '+%F %T')"

##############################################################################
hdr "2. What each node last decided"
##############################################################################

## Every gate in launch_job.sh ends with a traced `EXIT:` naming why it stopped;
## "nothing is running" is usually one such reason holding every node at once.
if [[ "${#last_reason_count[@]}" -eq 0 ]]; then
    note "no trace lines found"
else
    for key in "${!last_reason_count[@]}"; do
        printf '%6d\t%s\n' "${last_reason_count[$key]}" "${last_reason_example[$key]}"
    done | sort -rn | while IFS=$'\t' read -r count example; do
        node="${example%%: *}"; msg="${example#*: }"
        printf '  %5d node(s)  %s\n' "$count" "$msg"
        [[ "$count" -gt 1 ]] && printf '                 (e.g. %s)\n' "$node"
    done
fi

##############################################################################
hdr "3. Did anything actually get submitted in the last ${window_hours}h?"
##############################################################################

## The question section 2 cannot answer alone: a fleet of healthy-looking
## reasons is still consistent with no work having gone out all day.
if [[ "$submits" -gt 0 ]]; then
    note "$submits job(s) submitted -- the sequencer is reaching sbatch"
else
    bad "0 jobs submitted across ${#node_dirs[@]} node dir(s) in ${window_hours}h"
    note "if section 2 says 'every benchmark passing', that is correct and expected"
    note "otherwise the gate named there is what is holding the fleet"
fi
[[ "$submit_fail" -gt 0 ]] && bad "$submit_fail submission(s) were REJECTED by sbatch -- see section 4"

##############################################################################
hdr "4. Failures and warnings in the last ${window_hours}h"
##############################################################################

if [[ "${#event_count[@]}" -eq 0 ]]; then
    note "none"
else
    for key in "${!event_count[@]}"; do
        printf '%6d\t%s\n' "${event_count[$key]}" "${event_example[$key]}"
    done | sort -rn | while IFS=$'\t' read -r count example; do
        node="${example%%: *}"; msg="${example#*: }"
        printf '  %5d x  %s\n' "$count" "$msg"
        [[ "$count" -gt 1 ]] && printf '            (e.g. %s)\n' "$node"
    done
fi

##############################################################################
hdr "5. Health-check side"
##############################################################################

## node_health.sh writes logs/<node>/ and is what sets a node IDLE. A node it
## never ran on never leaves DOWN, so nothing can be scheduled there -- a stuck
## bringup with a healthy sequencer.
never_checked=()
for node_dir in "${node_dirs[@]}"; do
    node=$(basename "$node_dir")
    [[ -d "$logs_dir/$node" ]] || never_checked+=("$node")
done
if [[ "${#never_checked[@]}" -gt 0 ]]; then
    bad "${#never_checked[@]} node(s) have results/ but no logs/<node> -- health checks have never run there"
    printf '     %s\n' "${never_checked[@]:0:10}"
    [[ "${#never_checked[@]}" -gt 10 ]] && note "   ... and $(( ${#never_checked[@]} - 10 )) more"
else
    note "every matched node has a logs/<node> -- health checks have run"
fi

## The same distinction as section 1, for the other trigger: a health.log that
## has stopped being written is BCM, and a fresh one whose last line is an EXIT
## is a gate that named itself. See docs/explanation/health-cadence.md.
declare -A health_reason_count health_reason_example
health_missing=(); health_stale=(); health_fresh=0
for node_dir in "${node_dirs[@]}"; do
    node=$(basename "$node_dir")
    hlog="$node_dir/health.log"
    if [[ ! -f "$hlog" ]]; then
        health_missing+=("$node")
        continue
    fi
    hage=$(( now - $(stat -c %Y "$hlog" 2>/dev/null || echo 0) ))
    if [[ "$hage" -gt "$stale_secs" ]]; then
        health_stale+=("$node ${hage}s")
    else
        health_fresh=$((health_fresh + 1))
    fi
    hlast=$(tail -1 "$hlog" 2>/dev/null | cut -d' ' -f3-)
    [[ -z "$hlast" ]] && continue
    hkey=$(normalize "$hlast" "$node")
    (( health_reason_count["$hkey"]++ ))
    health_reason_example["$hkey"]="$node: $hlast"
done

if [[ "${#health_missing[@]}" -gt 0 ]]; then
    bad "${#health_missing[@]} node(s) have no results/<node>/health.log -- node_health.sh has not run since the cadence was deployed"
    printf '     %s\n' "${health_missing[@]:0:10}"
    [[ "${#health_missing[@]}" -gt 10 ]] && note "   ... and $(( ${#health_missing[@]} - 10 )) more"
fi
if [[ "${#health_stale[@]}" -gt 0 ]]; then
    bad "${#health_stale[@]} health.log(s) older than ${stale_minutes}m -- NodeHealthTrigger is not firing there. trigger-debug.sh."
    printf '     %s\n' "${health_stale[@]:0:10}"
fi
[[ "$health_fresh" -gt 0 ]] && note "$health_fresh health.log(s) written within ${stale_minutes}m"

if [[ "${#health_reason_count[@]}" -gt 0 ]]; then
    echo
    echo "  What each node's last health cycle decided:"
    for hkey in "${!health_reason_count[@]}"; do
        printf '%d\t%s\n' "${health_reason_count[$hkey]}" "${health_reason_example[$hkey]}"
    done | sort -rn | while IFS=$'\t' read -r count example; do
        node="${example%%: *}"; msg="${example#*: }"
        printf '  %5d x  %s\n' "$count" "$msg"
        [[ "$count" -gt 1 ]] && printf '            (e.g. %s)\n' "$node"
    done
    echo
    note "when a node is due to re-check: bash health-check.sh --explain"
fi

##############################################################################
[[ "$tail_lines" -gt 0 ]] && {
hdr "Raw trace, last $tail_lines line(s) per node"
for node_dir in "${node_dirs[@]}"; do
    node=$(basename "$node_dir")
    printf '\n-- %s\n' "$node"
    if [[ -f "$node_dir/trigger.log" ]]; then
        tail -n "$tail_lines" "$node_dir/trigger.log" | sed 's/^/  /'
    else
        printf '  (no trigger.log)\n'
    fi
done
}

##############################################################################
hdr "Summary"
##############################################################################

if [[ "$problems" -eq 0 ]]; then
    echo "  Nothing anomalous in the logs."
else
    echo "  $problems problem(s) flagged above."
fi
cat <<EOF

  Logs stale or missing (section 1)  -> ./trigger-debug.sh
  Logs fresh, gate closed (section 2) -> ask the node itself, no waiting:
      pdsh -R ssh -w <node> '$BRINGUP_HOME/actions/launch_job.sh --explain'
EOF

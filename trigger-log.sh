#!/bin/bash
#
# Usage: trigger-log.sh [-w hours] [-s minutes] [-t lines] [node-pattern]
#
# Answers "why is nothing running?" from the written record, rather than from
# the configuration. trigger-debug.sh walks BCM -> trigger -> script -> sbatch
# and names the link that is broken; this reads what the sequencer actually
# wrote at results/<node>/trigger.log and says what it decided, fleet-wide.
#
# The two are complementary, and which one to reach for depends on the answer
# to one question: is the trigger firing at all?
#
#   Logs stale or missing  -> nothing is running the script. trigger-debug.sh.
#   Logs fresh, no submits -> the script is running and every gate is closed.
#                             The reason is in section 2, already written down.
#
# That distinction is section 1, and it is the reason this script leads with
# timestamps instead of contents. A fleet whose logs all stopped an hour ago is
# a BCM problem and no amount of reading decisions will show it; a fleet with
# fresh logs and zero submissions is a gate problem and BCM is fine.
#
#   -w, --window <hours>   how far back to scan for events. Default 24.
#   -s, --stale <minutes>  a log older than this has stopped being written.
#                          Default 15 -- several BCM monitoring cycles, so a
#                          slow cycle or a node that just booted is not noise.
#   -t, --tail <lines>     lines of raw trace to print per node. Default 0
#                          (summary only); implied 20 when the pattern matches
#                          a single node, which is the "look at this one node"
#                          case and wants the trace, not a histogram of one.
#   pattern                node filter, same rules as status-check.sh: a bare
#                          string matches by prefix, globs are honored as
#                          written.
#
# Read-only. It submits nothing, drains nothing, changes nothing.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"      ## for BRINGUP_HOME, in the closing hint
results_dir="$home/results"
logs_dir="$home/logs"

window_hours=24
stale_minutes=15
tail_lines=-1          ## -1 means "not set", so the single-node default can tell
                       ## an explicit -t 0 from no flag at all.

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
        -h|--help)
            sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
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
node_dirs=("$results_dir"/$pattern/)

if [[ "${#node_dirs[@]}" -eq 0 ]]; then
    echo "ERROR: no node directories under $results_dir match '${args[0]:-*}'" >&2
    [[ -d "$results_dir" ]] || echo "       $results_dir does not exist -- the trigger has never run" >&2
    exit 1
fi

## Single node and no explicit -t: show the trace. Asking about one node is
## asking what it did, and a one-row summary of one node is just a worse tail.
if [[ "${#node_dirs[@]}" -eq 1 && "$tail_lines" -lt 0 ]]; then
    tail_lines=20
fi
[[ "$tail_lines" -lt 0 ]] && tail_lines=0

## Normalize a trace line into a group key. Node names and every number are
## replaced, because the interesting question is how many nodes stopped for the
## same *reason*, and the reason text carries the node name, an age in seconds,
## a queue depth and a countdown -- all of which differ per node and per cycle
## and would otherwise split one reason into one group per node.
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

    ## One pass per log: the last decision, and every notable event inside the
    ## window. Timestamps are `%F %T`, so a lexicographic compare against the
    ## cutoff is a chronological compare -- no date(1) per line.
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
                msg ~ /not known to slurm/)               { print "ev\t" msg }
        }
        END {
            if (last != "") print "last\t" last
            print "sub\t" (n + 0)
        }
    ' "$log")
    ## The file exists but holds no trace line. trace() in launch_job.sh sends
    ## its append to /dev/null on error, deliberately -- an unprivileged run
    ## should still print its trace rather than die on the log file -- so a
    ## trigger.log that cannot be written to stays empty and silent forever.
    ## Without this the node counts as fresh above and contributes nothing
    ## below, and the two section counts disagree with no reason given.
    [[ "$saw_decision" -eq 1 ]] || empty_log+=("$node")
done

##############################################################################
hdr "1. Is the trigger firing? (${#node_dirs[@]} node dir(s), stale = no write in ${stale_minutes}m)"
##############################################################################

## The framework-wide case first. If every log stopped, the sequencer is not
## being run anywhere and nothing below matters -- the decisions on screen are
## whatever was true when it stopped, which is exactly the trap this section
## exists to avoid.
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

## Every gate in launch_job.sh ends with a traced `EXIT:` naming why it
## stopped. Grouped, a whole fleet collapses to a handful of reasons -- and
## "nothing is running" is usually one reason holding every node at once.
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

## The question section 2 cannot answer on its own. Every node reporting a
## healthy-looking reason is still consistent with a fleet that has run nothing
## all day -- "every benchmark passing" and "next sweep in Ns" both look fine
## and both mean no work went out.
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

## node_health.sh writes logs/<node>/ and is what sets a node IDLE in the first
## place. A node it never ran on never leaves DOWN, so no benchmark can be
## scheduled there -- which reads as "nothing is running" with a perfectly
## healthy sequencer, because the sequencer is not the thing that is stuck.
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
      pdsh -w <node> '$BRINGUP_HOME/actions/launch_job.sh --explain'
EOF

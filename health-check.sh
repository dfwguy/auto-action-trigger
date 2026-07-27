#!/bin/bash
#
# Usage: health-check.sh [--full] [--summary] [pattern]
#
#   pattern  optional node-name filter. A bare string matches every node whose
#            name starts with it, so a rack prefix (dh01-rack01) covers the
#            whole rack. Shell globs (dh01-rack0[12]*, *node05) are honored as
#            written, so an explicit pattern can match anywhere in the name.
#            With no pattern, every node Slurm knows about is reported.
#
#   --full   print every failure pattern, check name and drain reason. The
#            default output elides the tail of each so the report stays a fixed
#            size as the cluster grows.
#
#   --summary
#            roll-up instead of the grouped report: every node placed in exactly
#            one of PASSING / FAILING HEALTH CHECKS / NOT CHECKED / OTHER
#            DRAINS, with the full node list for each. Answers "where does each
#            node stand" rather than "what do I fix".
#
# Cluster-wide summary of health-check failures, grouped by what has to be
# fixed rather than by what has to be fixed on: 60 nodes that all fail the same
# 38 checks are one out-of-spec image, and printing them as 38 check lines over
# 60 node lines reads as 2280 incidents. Nodes are grouped by their exact set of
# failing checks, so one group is one fix.
#
# node_health.sh drains a node with the names of the checks that mismatched the
# baseline, so the Slurm reason field is the source of truth here -- no node is
# contacted and nothing is re-run. Use node-health-refresh.sh to re-run checks
# and sync-check.sh to see the actual diff for a node named below.
#
# That makes this report only as complete as the drains behind it. With
# DRAIN_AFTER_FAILED_HEALTH_CHECK=no -- the shipped default -- node_health.sh
# records failures and never drains, so nothing reaches the reason field and
# every node reads as PASSING here. The banner below says so rather than
# leaving a clean report to be read as a clean cluster. Until drains are turned
# on, sync-check.sh is the tool that answers "is this node in spec": it diffs
# the logs directly and does not go through Slurm at all.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
logs_dir="$home/logs"
valid_dir="$home/valid-config/default"

# Parse before loading Slurm, so --help works on a host that has neither.
full=0
summary=0
args=()
for arg in "$@"; do
    case "$arg" in
        --full|-f)    full=1 ;;
        --summary|-s) summary=1 ;;
        -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)            args+=("$arg") ;;
    esac
done

if ! command -v sinfo &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

# How many entries each elided list shows before it collapses to a count.
max_groups=6
max_checks=8
max_reasons=8
if [[ "$full" -eq 1 ]]; then
    max_groups=100000; max_checks=100000; max_reasons=100000
fi

# Width to wrap node lists at. tput falls back to the terminfo default when
# stdout is not a tty, which is what we want for a redirect into a file.
width="${COLUMNS:-}"
[[ -z "$width" ]] && width=$(tput cols 2>/dev/null)
[[ -z "$width" || "$width" -lt 60 ]] && width=100

# Files node_health.sh writes into logs/<node>/ that are not checks.
is_not_a_check() {
    case "$1" in
        refresh|script-env) return 0 ;;
        *)                  return 1 ;;
    esac
}

# The set of valid check names. Taken from the baseline first, then widened with
# anything present under logs/ -- a check added to node_health.sh after the last
# set-valid-default.sh run has log output but no baseline entry yet, and it still
# needs to be recognized as a check rather than dismissed as operator text.
declare -A known_check baseline_has
if [[ -d "$valid_dir" ]]; then
    while IFS= read -r name; do
        is_not_a_check "$name" && continue
        known_check["$name"]=1
        baseline_has["$name"]=1
    done < <(find -L "$valid_dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
fi
if [[ -d "$logs_dir" ]]; then
    while IFS= read -r name; do
        is_not_a_check "$name" && continue
        known_check["$name"]=1
    done < <(find "$logs_dir" -mindepth 2 -maxdepth 2 -type f -printf '%f\n' 2>/dev/null)
fi

if [[ "${#known_check[@]}" -eq 0 ]]; then
    echo "ERROR: no check names found in $valid_dir or $logs_dir" >&2
    echo "       Without them every drain looks like an operator drain, so this" >&2
    echo "       script would report nothing rather than report wrongly. Run" >&2
    echo "       set-valid-default.sh against a validated node first." >&2
    exit 1
fi

# node_health.sh's reason headers do not all match the log file they came from.
# Shared with sync-check.sh so the two cannot drift.
if [[ ! -f "$home/reason-map.sh" ]]; then
    echo "ERROR: $home/reason-map.sh is missing -- it carries the reason-to-check" >&2
    echo "       name mapping and without it every drain reason parses as text." >&2
    exit 1
fi
source "$home/reason-map.sh"

compress() {
    local list="$1" out
    out=$(scontrol show hostlistsorted "$list" 2>/dev/null)
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
    else
        printf '%s' "$list"
    fi
}

plural() {
    [[ "$1" -eq 1 ]] && printf 'node' || printf 'nodes'
}

count_list() {
    [[ -z "$1" ]] && { printf 0; return; }
    printf '%s' "$(( $(tr -cd ',' <<< "$1" | wc -c) + 1 ))"
}

# Break a comma-separated list into chunks no wider than $2, splitting only at
# top-level commas -- a break inside a [14,29,34] range yields two lists that
# neither scontrol nor a copy-paste will take. Emits bare chunks; the caller
# supplies the label and continuation indent.
wrap_list() {
    awk -v text="$1" -v avail="$2" '
    BEGIN {
        if (avail < 20) avail = 20
        n = length(text); depth = 0; start = 1; line = ""
        for (i = 1; i <= n; i++) {
            c = substr(text, i, 1)
            if (c == "[") depth++
            else if (c == "]") depth--
            else if (c == "," && depth == 0) {
                emit(substr(text, start, i - start + 1))
                start = i + 1
            }
        }
        emit(substr(text, start, n - start + 1))
        if (line != "") print line
    }
    function emit(piece) {
        if (line != "" && length(line) + length(piece) > avail) {
            print line; line = ""
        }
        if (line == "") sub(/^ +/, "", piece)
        line = line piece
    }'
}

# Print "<label><list>" wrapped, with continuation lines indented to match. A
# third argument caps the number of lines -- for the informational sections a
# full hostlist is pages of output nobody reads, and --full still has it.
print_wrapped() {
    local label="$1" text="$2" max_lines="${3:-0}" cont first=1 chunk n=0
    [[ "$full" -eq 1 ]] && max_lines=0
    printf -v cont '%*s' "${#label}" ''
    while IFS= read -r chunk; do
        ((n++))
        if [[ "$max_lines" -gt 0 && "$n" -gt "$max_lines" ]]; then
            printf '%s...\n' "$cont"
            break
        fi
        if [[ "$first" -eq 1 ]]; then
            printf '%s%s\n' "$label" "$chunk"; first=0
        else
            printf '%s%s\n' "$cont" "$chunk"
        fi
    done < <(wrap_list "$text" $(( width - ${#label} )))
}

# Elide a ", "-separated list down to $2 entries plus a count.
elide() {
    local list="$1" limit="$2"
    local -a items
    IFS=',' read -r -a items <<< "$list"
    if [[ "${#items[@]}" -le "$limit" ]]; then
        printf '%s' "$list"
        return
    fi
    local shown="" i
    for ((i = 0; i < limit; i++)); do
        shown+="${items[i]#"${items[i]%%[![:space:]]*}"}, "
    done
    printf '%s+%d more' "$shown" "$(( ${#items[@]} - limit ))"
}

declare -A seen_node reason_nodes sig_nodes check_count
total=0 failing=0 other=0 passing=0 unchecked=0
passing_nodes="" unchecked_nodes="" failing_nodes="" other_nodes=""

while IFS='|' read -r node state reason; do
    [[ -z "$node" ]] && continue
    # sinfo -N lists a node once per partition it belongs to.
    [[ -n "${seen_node[$node]}" ]] && continue
    seen_node["$node"]=1

    [[ "$node" == $pattern ]] || continue
    ((total++))

    if [[ -z "$reason" || "$reason" == "none" ]]; then
        # No reason at all. node_health.sh sets IDLE with no reason on a clean
        # pass, so an available node here is a node whose checks all passed --
        # but only if they ran. A node with no logs/<node> has never been
        # checked, which is not the same thing and must not be counted as a
        # pass. A node down with no reason is neither; leave it with the other
        # drains rather than claim it is healthy.
        case "$state" in
            *down*|*drain*|*fail*|*unk*|*error*)
                ((other++))
                other_nodes+="$node,"
                reason_nodes["$state|(no reason recorded)"]+="$node,"
                ;;
            *)
                if [[ -d "$logs_dir/$node" ]]; then
                    ((passing++)); passing_nodes+="$node,"
                else
                    ((unchecked++)); unchecked_nodes+="$node,"
                fi
                ;;
        esac
        continue
    fi

    matched=""
    for raw in $(canonicalize_reason "$reason"); do
        name=$(resolve_token "$raw")
        [[ -n "${known_check[$name]}" ]] || continue
        # A check can appear twice in one reason (dmesg-xid carries its own
        # output, which can echo a name back); count the node once per check.
        [[ " $matched " == *" $name "* ]] && continue
        matched+="$name "
    done

    if [[ -z "$matched" ]]; then
        # Nothing in the reason is a check name, so node_health.sh did not write
        # it -- an operator drain, or a drain from launch_job.sh.
        ((other++))
        other_nodes+="$node,"
        reason_nodes["$state|$reason"]+="$node,"
        continue
    fi

    ((failing++))
    failing_nodes+="$node,"
    # Sort the names so two nodes failing the same checks in a different order
    # land in the same group.
    sig=$(tr ' ' '\n' <<< "${matched% }" | sort | tr '\n' ' ')
    sig="${sig% }"
    sig_nodes["$sig"]+="$node,"
    for name in $sig; do
        (( check_count["$name"]++ ))
    done
done < <(sinfo -N -h -o '%N|%T|%E' 2>/dev/null)

if [[ "$total" -eq 0 ]]; then
    echo "No nodes match '${args[0]:-*}'" >&2
    exit 1
fi

# A dangling or missing baseline makes every check fail on every node that ran,
# and none of those failures are real. That has to lead, not trail: the whole
# report below it is an artifact.
if [[ ! -d "$valid_dir" ]]; then
    echo "WARNING: no baseline — $valid_dir does not resolve"
    if [[ -L "$valid_dir" ]]; then
        echo "         the symlink points at $(readlink "$valid_dir"), which does not exist"
    fi
    echo "         Every check diffs against a missing file, so the failures below are"
    echo "         artifacts of the missing baseline, not node faults. Fix it first:"
    echo "             rm -f $valid_dir"
    echo "             bash set-valid-default.sh <validated-node>"
    echo
fi

# Drains off means this report has nothing to read. Say it at the top, for the
# same reason the baseline warning is at the top: an empty report and a healthy
# cluster look identical, and only one of them is worth trusting.
if ! setting_enabled "$DRAIN_AFTER_FAILED_HEALTH_CHECK"; then
    echo "NOTE: DRAIN_AFTER_FAILED_HEALTH_CHECK=$DRAIN_AFTER_FAILED_HEALTH_CHECK in ${SETTINGS_FILE##*/}"
    echo "      node_health.sh records failures without draining, so a failing node"
    echo "      carries no Slurm reason and is reported below as passing. This report"
    echo "      is complete only once drains are on. Until then:"
    echo "          bash sync-check.sh <node>     # diff the logs directly"
    echo
fi

# --summary: every node placed in exactly one bucket, with the full list for
# each. The grouped report answers "what do I fix"; this answers "where does
# each node stand", which is the roll-up question and a different one.
if [[ "$summary" -eq 1 ]]; then
    echo "SUMMARY — $total $(plural "$total")"
    echo
    bucket() {
        local title="$1" count="$2" list="$3" note="$4"
        [[ "$count" -eq 0 ]] && return
        printf '%s — %d %s' "$title" "$count" "$(plural "$count")"
        [[ -n "$note" ]] && printf ' (%s)' "$note"
        printf '\n'
        print_wrapped "  " "$(compress "${list%,}")"
        echo
    }
    bucket "PASSING" "$passing" "$passing_nodes" \
        "checks ran, nothing mismatched the baseline"
    bucket "FAILING HEALTH CHECKS" "$failing" "$failing_nodes" \
        "drained by node_health.sh"
    bucket "NOT CHECKED" "$unchecked" "$unchecked_nodes" \
        "available, but no logs/<node> — checks have never run"
    bucket "OTHER DRAINS" "$other" "$other_nodes" \
        "operator or sequencer; health state not visible in Slurm"
    if [[ ! -d "$valid_dir" ]]; then
        echo "PASSING is not meaningful while the baseline is missing: a node can only"
        echo "reach it by having no reason recorded, not by matching anything."
    fi
    exit 0
fi

if [[ "$failing" -eq 0 ]]; then
    echo "No failed health checks — $total $(plural "$total") checked"
else
    # One group per distinct set of failing checks, largest first. Sorting on the
    # node count puts the fix that clears the most nodes at the top.
    mapfile -t groups < <(
        for sig in "${!sig_nodes[@]}"; do
            printf '%s|%s\n' "$(count_list "${sig_nodes[$sig]%,}")" "$sig"
        done | sort -t'|' -k1,1nr -k2,2
    )

    if [[ "${#groups[@]}" -eq 1 ]]; then
        echo "FAILED HEALTH CHECKS — $failing of $total $(plural "$total"), all failing the same checks"
    else
        echo "FAILED HEALTH CHECKS — $failing of $total $(plural "$total") in ${#groups[@]} patterns"
    fi
    echo

    shown=0
    hidden_nodes=0
    for entry in "${groups[@]}"; do
        count="${entry%%|*}"
        sig="${entry#*|}"
        if [[ "$shown" -ge "$max_groups" ]]; then
            (( hidden_nodes += count ))
            continue
        fi
        ((shown++))
        n_checks=$(wc -w <<< "$sig")
        [[ "${#groups[@]}" -gt 1 ]] && printf '[%d] ' "$shown"
        printf '%d %s × %d %s\n' \
            "$n_checks" "$([[ "$n_checks" -eq 1 ]] && echo check || echo checks)" \
            "$count" "$(plural "$count")"
        print_wrapped "    checks  " "$(elide "${sig// /, }" "$max_checks")"
        print_wrapped "    nodes   " "$(compress "${sig_nodes[$sig]%,}")"
        echo
    done

    if [[ "$hidden_nodes" -gt 0 ]]; then
        printf '... %d more %s covering %d %s — rerun with --full\n\n' \
            "$(( ${#groups[@]} - shown ))" \
            "$([[ $(( ${#groups[@]} - shown )) -eq 1 ]] && echo pattern || echo patterns)" \
            "$hidden_nodes" "$(plural "$hidden_nodes")"
    fi

    # With one group the per-check tally just restates it. With several it is the
    # only place you can see that one check spans more than one pattern.
    if [[ "${#groups[@]}" -gt 1 ]]; then
        tally=$(
            for name in "${!check_count[@]}"; do
                printf '%s|%s %s\n' "${check_count[$name]}" "$name" "${check_count[$name]}"
            done | sort -t'|' -k1,1nr -k2,2 | cut -d'|' -f2 | paste -sd',' -
        )
        print_wrapped "By check:  " "$(elide "${tally//,/, }" $(( max_checks * 2 )))"
        echo
    fi
fi

# A check with log output but no baseline entry can never pass: node_health.sh
# diffs against a file that is not there. Worth calling out separately -- the fix
# is a new baseline, not anything on the node. Suppressed when the baseline is
# missing outright, since the banner above already said so.
if [[ -d "$valid_dir" ]]; then
    missing=""
    for name in "${!check_count[@]}"; do
        [[ -n "${baseline_has[$name]}" ]] || missing+="$name,"
    done
    if [[ -n "$missing" ]]; then
        n_missing=$(count_list "${missing%,}")
        echo "No baseline in $valid_dir — $n_missing $([[ "$n_missing" -eq 1 ]] && echo check || echo checks) can never pass:"
        print_wrapped "  " "$(elide "$(tr ',' '\n' <<< "${missing%,}" | sort | paste -sd',' - | sed 's/,/, /g')" "$max_checks")"
        echo
    fi
fi

# Grouped by reason, not by node: eighteen racks powered off by CMDaemon is one
# line, and it stays one line however many racks get added.
if [[ "$other" -gt 0 ]]; then
    echo "Not health drains — $other $(plural "$other") (operator, or the job sequencer):"
    mapfile -t reasons < <(
        for key in "${!reason_nodes[@]}"; do
            printf '%s|%s\n' "$(count_list "${reason_nodes[$key]%,}")" "$key"
        done | sort -t'|' -k1,1nr -k2,2
    )
    shown=0
    hidden=0
    for entry in "${reasons[@]}"; do
        count="${entry%%|*}"
        key="${entry#*|}"
        state="${key%%|*}"
        reason="${key#*|}"
        if [[ "$shown" -ge "$max_reasons" ]]; then
            (( hidden += count )); continue
        fi
        ((shown++))
        printf '  %-14s %-40s %4d %s\n' "$state" "$reason" "$count" "$(plural "$count")"
        print_wrapped "      " "$(compress "${reason_nodes[$key]%,}")" 3
    done
    if [[ "$hidden" -gt 0 ]]; then
        printf '  ... %d more %s covering %d %s — rerun with --full\n' \
            "$(( ${#reasons[@]} - shown ))" \
            "$([[ $(( ${#reasons[@]} - shown )) -eq 1 ]] && echo reason || echo reasons)" \
            "$hidden" "$(plural "$hidden")"
    fi
    echo
fi

if [[ "$failing" -gt 0 ]]; then
    # One node per pattern is enough to diff: every node in a pattern failed the
    # same checks. Handing sync-check.sh all 60 buries the answer in 60 copies.
    first_sig="${groups[0]#*|}"
    first_node="${sig_nodes[$first_sig]%%,*}"
    echo "Why a node failed:  bash sync-check.sh $first_node"
    [[ "${#groups[@]}" -gt 1 ]] && echo "                    (one node from pattern 1; each pattern needs its own diff)"
    echo "Re-run the checks:  bash node-health-refresh.sh <node|nodelist>"
fi

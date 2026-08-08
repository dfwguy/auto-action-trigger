#!/bin/bash
#
# Usage: health-check.sh [--full] [--summary] [pattern]
#        health-check.sh --explain [pattern]
#        health-check.sh --refresh <node|nodelist> [...]
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
#   --explain
#            the cadence rather than the findings: when the checks last ran on
#            each node, what that run concluded, and when the next one is due.
#            Answers "why has this node not re-checked", which the report below
#            cannot -- it reads Slurm, and a node that has stopped checking
#            keeps whatever reason it had.
#
#   --refresh <node|nodelist> [...]
#            queue an immediate re-check on the named nodes by setting the
#            refresh sentinel, instead of waiting out HEALTH_INTERVAL_HOURS.
#            Takes node names and Slurm nodelists (node00[1-18]), repeatable.
#            Nothing else is read or printed.
#
# Cluster-wide summary of health-check failures, grouped by what has to be
# fixed rather than by what has to be fixed on: 60 nodes that all fail the same
# 38 checks are one out-of-spec image, and printing them as 38 check lines over
# 60 node lines reads as 2280 incidents. Nodes are grouped by their exact set of
# failing checks, so one group is one fix.
#
# node_health.sh drains a node with the names of the checks that mismatched the
# baseline, so the Slurm reason field is the source of truth here -- no node is
# contacted and nothing is re-run. Use --refresh to re-run the checks and
# sync-check.sh to see the actual diff for a node named below.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---
#
# Only as complete as the drains behind it: with the shipped
# DRAIN_AFTER_FAILED_HEALTH_CHECK=no every node reads as PASSING, and the banner
# below says so. See docs/how-to/manage-drains.md.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
logs_dir="$home/logs"
valid_dir="$home/valid-config/default"

# Parse before loading Slurm, so --help works on a host that has neither.
full=0
summary=0
explain=0
refresh=0
args=()
for arg in "$@"; do
    case "$arg" in
        --full|-f)    full=1 ;;
        --summary|-s) summary=1 ;;
        --explain|-n) explain=1 ;;
        --refresh|-r) refresh=1 ;;
        -h|--help)    sed -n '2,45p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)            args+=("$arg") ;;
    esac
done

if ! command -v sinfo &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

## Above the three modes below, all of which filter on it.
pattern="${args[0]}"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

## Writes the sentinel node_health.sh consumes, and stops: the report below
## reads Slurm, which does not yet know about the re-check just asked for.
## See docs/explanation/health-cadence.md#asking-for-a-re-check.
if [[ "$refresh" -eq 1 ]]; then
    if [[ "${#args[@]}" -eq 0 ]]; then
        echo "ERROR: --refresh needs at least one node or nodelist -- nothing was queued." >&2
        echo "       bash health-check.sh --refresh node001 'node00[2-9]'" >&2
        exit 2
    fi
    for arg in "${args[@]}"; do
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            if [[ -d "$logs_dir/$node" ]]; then
                if touch "$logs_dir/$node/refresh" 2>/dev/null; then
                    echo "Refresh queued for $node"
                else
                    echo "ERROR: cannot write $logs_dir/$node/refresh as $(id -un) -- $node will re-check on its own cadence instead." >&2
                fi
            else
                echo "No health log for $node in $logs_dir — it will run fresh on its next monitoring cycle"
            fi
        done < <(scontrol show hostnames "$arg" 2>/dev/null || echo "$arg")
    done
    exit 0
fi

## Read from the stamp rather than from Slurm: with drains off a failing node
## carries no reason. See docs/explanation/health-cadence.md#the-stamp-file.
if [[ "$explain" -eq 1 ]]; then
    if setting_enabled "$PAUSE_HEALTH_CHECKS"; then
        echo "NOTE: PAUSE_HEALTH_CHECKS=$PAUSE_HEALTH_CHECKS in ${SETTINGS_FILE##*/} — no node re-checks,"
        echo "      and the due times below are what will be acted on once it goes back to no."
        echo
    fi
    printf '%-28s %-20s %-8s %s\n' NODE 'LAST RUN' OUTCOME 'NEXT DUE'
    now=$(date +%s)
    shown=0
    for dir in "$logs_dir"/*/; do
        node=$(basename "$dir")
        # shellcheck disable=SC2053  # $pattern is the caller's node glob
        [[ "$node" == $pattern ]] || continue
        ((shown++))
        if [[ -f "$dir/.last-check" ]]; then
            IFS=$'\t' read -r epoch outcome < "$dir/.last-check"
        else
            epoch=""; outcome=""
        fi
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
            printf '%-28s %-20s %-8s %s\n' "$node" '(never)' '-' 'next monitoring cycle'
            continue
        fi
        hours="$HEALTH_INTERVAL_HOURS"
        [[ "$outcome" == "failed" ]] && hours="$HEALTH_RETRY_INTERVAL_HOURS"
        if [[ -f "$dir/refresh" ]]; then
            due='refresh queued'
        elif [[ ! "$hours" =~ ^[0-9]+$ || "$hours" -eq 0 ]]; then
            due='never (cadence off)'
        elif [[ $(( now - epoch )) -ge $(( hours * 3600 )) ]]; then
            due="overdue by $(( (now - epoch) / 3600 - hours ))h"
        else
            due="in $(( (hours * 3600 - (now - epoch)) / 60 ))m"
        fi
        printf '%-28s %-20s %-8s %s\n' \
            "$node" "$(date -d "@$epoch" '+%F %T')" "$outcome" "$due"
    done
    if [[ "$shown" -eq 0 ]]; then
        echo "No node under $logs_dir matches '${args[0]:-*}' — the checks have never run on any of them." >&2
        exit 1
    fi
    echo
    echo "Why a run stopped:  tail results/<node>/health.log"
    exit 0
fi

# How many entries each elided list shows before it collapses to a count.
max_groups=6
max_checks=8
max_reasons=8
if [[ "$full" -eq 1 ]]; then
    max_groups=100000; max_checks=100000; max_reasons=100000
fi

if [[ ! -f "$home/report-format.sh" ]]; then
    echo "ERROR: $home/report-format.sh is missing -- it carries the node-list" >&2
    echo "       compression and wrapping this report is printed through." >&2
    exit 1
fi
REPORT_FULL="$full"
source "$home/report-format.sh"

# Files node_health.sh writes into logs/<node>/ that are not checks.
is_not_a_check() {
    case "$1" in
        refresh|script-env|.last-check) return 0 ;;
        *)                              return 1 ;;
    esac
}

# Valid check names: the baseline, widened with logs/ -- a check newer than the
# last set-valid-default.sh run has no baseline entry yet and would otherwise be
# dismissed as operator text. See docs/how-to/add-a-health-check-set.md#set-the-baseline-first.
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

declare -A seen_node reason_nodes sig_nodes check_count
total=0 failing=0 other=0 passing=0 unchecked=0
passing_nodes="" unchecked_nodes="" failing_nodes="" other_nodes=""

while IFS='|' read -r node state reason; do
    [[ -z "$node" ]] && continue
    # sinfo -N lists a node once per partition it belongs to.
    [[ -n "${seen_node[$node]}" ]] && continue
    seen_node["$node"]=1

    # shellcheck disable=SC2053  # $pattern is the caller's node glob; quoting
    # it would only ever match a literal node named '*'.
    [[ "$node" == $pattern ]] || continue
    ((total++))

    if [[ -z "$reason" || "$reason" == "none" ]]; then
        # No reason: available splits on whether logs/<node> exists, since a
        # never-checked node is not a passing one. Down with no reason is
        # neither, so it goes with the other drains. docs/reference/scripts.md#--summary.
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
        # dmesg-xid carries its own output, which can echo a check name back;
        # count the node once per check.
        [[ " $matched " == *" $name "* ]] && continue
        matched+="$name "
    done

    if [[ -z "$matched" ]]; then
        # No check name in the reason, so node_health.sh did not write it -- an
        # operator drain, or one from launch_job.sh.
        ((other++))
        other_nodes+="$node,"
        reason_nodes["$state|$reason"]+="$node,"
        continue
    fi

    ((failing++))
    failing_nodes+="$node,"
    # Sorted, so the same checks in a different order land in the same group.
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

# A missing baseline fails every check on every node that ran, so this leads
# rather than trails: the whole report below it is an artifact.
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

# Paused means nothing re-runs, so this is a snapshot of whatever was true when
# the pause went on. See docs/how-to/pause-and-resume.md.
if setting_enabled "$PAUSE_HEALTH_CHECKS"; then
    echo "NOTE: PAUSE_HEALTH_CHECKS=$PAUSE_HEALTH_CHECKS in ${SETTINGS_FILE##*/}"
    echo "      node_health.sh is not running on any node, so nothing below can change"
    echo "      and a --refresh request will not be picked up until this is set"
    echo "      back to no."
    echo
fi

# Drains off means this report has nothing to read, and an empty report looks
# exactly like a healthy cluster. See docs/how-to/manage-drains.md.
if ! setting_enabled "$DRAIN_AFTER_FAILED_HEALTH_CHECK"; then
    echo "NOTE: DRAIN_AFTER_FAILED_HEALTH_CHECK=$DRAIN_AFTER_FAILED_HEALTH_CHECK in ${SETTINGS_FILE##*/}"
    echo "      node_health.sh records failures without draining, so a failing node"
    echo "      carries no Slurm reason and is reported below as passing. This report"
    echo "      is complete only once drains are on. Until then:"
    echo "          bash sync-check.sh <node>     # diff the logs directly"
    echo
fi

# --summary: every node in exactly one bucket, full list for each. See
# docs/reference/scripts.md#--summary.
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
    # One group per distinct set of failing checks, largest first, so the fix
    # that clears the most nodes leads.
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

    # With one group the tally restates it; with several it is the only place a
    # check spanning more than one pattern shows up.
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

# A check with no baseline entry can never pass, and the fix is a new baseline
# rather than anything on the node. Suppressed when the baseline is missing
# outright -- the banner above already said so.
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
# line, and stays one line however many racks get added.
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
    # One node per pattern is enough to diff -- the rest failed the same checks,
    # and 60 copies of one diff buries the answer.
    first_sig="${groups[0]#*|}"
    first_node="${sig_nodes[$first_sig]%%,*}"
    echo "Why a node failed:  bash sync-check.sh $first_node"
    [[ "${#groups[@]}" -gt 1 ]] && echo "                    (one node from pattern 1; each pattern needs its own diff)"
    echo "Re-run the checks:  bash health-check.sh --refresh <node|nodelist>"
fi

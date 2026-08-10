#!/bin/bash
#
# Usage: health-check.sh [--drained] [--summary [--by-state]] [<nodes> ...]
#        health-check.sh --individual|-i <check> [<nodes> ...]
#        health-check.sh --diff|-D [--all] <nodes> ...
#        health-check.sh --explain [<nodes> ...]
#        health-check.sh --refresh <node|nodelist> [...]
#
#   <nodes>  optional node filter, repeatable, and the same three spellings in
#            every mode above. A Slurm nodelist (dh01-h02-[11-14], or a comma
#            list) is expanded through `scontrol show hostnames` and matches
#            exactly those nodes. A bare string matches every node whose name
#            starts with it, so a rack prefix (dh01-rack01) covers the whole
#            rack. A shell glob (dh01-rack0[12]*, *node05) is honored as
#            written, so an explicit pattern can match anywhere in the name --
#            and a glob is anything carrying a `*` or a `?`, brackets alone
#            being a nodelist.
#
#            Several arguments are one report over all of them, so a list from
#            another tool composes directly rather than through a loop that
#            prints one report per node:
#                bash health-check.sh $(nodeset -e @IDLE)
#                bash health-check.sh "$(sinfo -h -t drain -o %N)"
#            A name nothing matches is named rather than dropped. With no
#            argument, every node Slurm knows about is reported.
#
#   --drained
#            what is out of the queue rather than what is broken: every drained
#            or down node grouped by the reason it carries, largest group first,
#            with the node list under each. `sinfo -R` answers the same question
#            one node at a time, which on a rack powered off by CMDaemon is
#            eighteen lines of one event.
#
#   --summary
#            the per-check roll-up instead of the grouped report: one line per
#            failing check with every node under it, the checks with no baseline
#            entry, and the nodes that have never been checked. The same block
#            overall_report.sh prints, from the same numbers.
#
#   --by-state
#            --summary split into one block per Slurm state, each with its own
#            per-check tally. Answers "how much of this would a drain actually
#            take out", which the flat roll-up cannot: it counts a node already
#            drained the same as one still taking work. Implies --summary.
#
#   --explain
#            the cadence rather than the findings: when the checks last ran on
#            each node, what that run concluded, and when the next one is due.
#            Answers "why has this node not re-checked", which the report below
#            cannot -- it reads a snapshot of the logs, and a node that has
#            stopped checking keeps whatever it last wrote. A node whose
#            heartbeat has gone stale is reported as not cycling instead of
#            being given a due time nothing will act on.
#
#   --individual|-i <check> [<nodes> ...]
#            group nodes whose <check> log file is byte-for-byte identical,
#            largest group first, with a compressed node list and the file
#            content under each. Shows the actual values across the fleet.
#            Reads no Slurm state.
#
#   --diff|-D [--all] <nodes> ...
#            why one node failed: each of its failing checks diffed against
#            valid-config/default. Read the direction carefully -- `<` is the
#            node and `>` is the baseline, and reading it backwards turns one
#            bad baseline into a fleet of bad nodes. Which checks are diffed
#            comes from the logs, not from the Slurm drain reason, so a node
#            nothing drained still explains itself. --all diffs every gated
#            check rather than only the failing ones, which is what to reach
#            for when the baseline itself is in question.
#
#   --refresh <node|nodelist> [...]
#            queue an immediate re-check on the named nodes by setting the
#            refresh sentinel, instead of waiting out HEALTH_INTERVAL_HOURS.
#            Takes node names and Slurm nodelists (node00[1-18]), repeatable.
#            Nothing else is read or printed, and no node is contacted -- so a
#            node that has stopped cycling is queued successfully and says so,
#            because the sentinel is consumed on the node and not here.
#
# Cluster-wide summary of health-check failures, grouped by what has to be
# fixed rather than by what has to be fixed on: 60 nodes that all fail the same
# 38 checks are one out-of-spec image, and printing them as 38 check lines over
# 60 node lines reads as 2280 incidents. Nodes are grouped by their exact set of
# failing checks, so one group is one fix.
#
# The failures are read from logs/<node>/<check> against valid-config/default --
# the same comparison node_health.sh drains on -- so this is complete whether or
# not DRAIN_AFTER_FAILED_HEALTH_CHECK is on. Slurm is asked for node state and
# for drains this framework did not write, nothing else. No node is contacted
# and no check is re-run: use --refresh for that, and --diff for the per-node
# diff behind a check name below.
# --- end of --help text; tests/help-text-test.sh keeps the -h range in step ---

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
logs_dir="$home/logs"
results_dir="$home/results"
valid_dir="$home/valid-config/default"

# Parse before loading Slurm, so --help works on a host that has neither.
drained=0
summary=0
by_state=0
explain=0
individual=0
diff_mode=0
all=0
refresh=0
args=()
for arg in "$@"; do
    case "$arg" in
        --drained|-d)    drained=1 ;;
        --summary|-s)    summary=1 ;;
        --by-state|-b)   by_state=1; summary=1 ;;
        --explain|-n)    explain=1 ;;
        --individual|-i) individual=1 ;;
        --diff|-D)       diff_mode=1 ;;
        --all|-a)        all=1 ;;
        --refresh|-r)    refresh=1 ;;
        -h|--help)     sed -n '2,90p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)             args+=("$arg") ;;
    esac
done

if [[ "$summary" -eq 1 && "$drained" -eq 1 ]]; then
    echo "ERROR: --summary and --drained are two reports, not two filters -- one" >&2
    echo "       groups failures by check, the other groups drains by reason." >&2
    echo "       Ask for one of them." >&2
    exit 2
fi
## Its first argument is a check name rather than a node pattern, so combining
## it would silently reinterpret the caller's argument.
if [[ "$individual" -eq 1 && ( "$summary" -eq 1 || "$drained" -eq 1 ) ]]; then
    echo "ERROR: --individual is its own report -- it takes a check name, not a" >&2
    echo "       node pattern, so it cannot be combined with --summary or" >&2
    echo "       --drained. Ask for one of them." >&2
    exit 2
fi
if [[ "$diff_mode" -eq 1 && ( "$summary" -eq 1 || "$drained" -eq 1 || "$individual" -eq 1 ) ]]; then
    echo "ERROR: --diff is its own report -- it prints one node's checks against" >&2
    echo "       the baseline, not a fleet roll-up. Ask for one of them." >&2
    exit 2
fi
## --all only widens the set --diff walks; silently ignoring it elsewhere would
## read as a filter that did nothing.
if [[ "$all" -eq 1 && "$diff_mode" -ne 1 ]]; then
    echo "ERROR: --all only means something with --diff, where it diffs every" >&2
    echo "       check rather than the failing ones. Nothing else elides by check." >&2
    exit 2
fi
if ! command -v sinfo &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

# Above every mode: --refresh compresses the node list it suggests, and reads
# scontrol to do it, so this follows the module load rather than the report.
if [[ ! -f "$home/report-format.sh" ]]; then
    echo "ERROR: $home/report-format.sh is missing -- it carries the node-list" >&2
    echo "       compression and wrapping this report is printed through." >&2
    exit 1
fi
REPORT_FULL=$(( summary || drained || individual ))
source "$home/report-format.sh"

# What the filter was asked for, for the messages that report matching nothing.
filter_desc() { local d="${NODE_PATTERN_SRC[*]}"; printf '%s' "${d// /, }"; }

# What the filter named and this report has nothing for. Leads the report: an
# argument silently dropped reads exactly like a node with nothing to say.
report_unmatched() {
    local missed
    missed=$(node_filter_unmatched)
    [[ -z "$missed" ]] && return 0
    print_wrapped "NOTE: nothing matched: " "$missed"
    echo "      Nothing under Slurm or $logs_dir answers to those. Brackets are a"
    echo "      Slurm nodelist here and not a glob -- for a glob, add a '*'."
    echo
}

## Writes the sentinel node_health.sh consumes, and stops: the report below
## reads Slurm, which does not yet know about the re-check just asked for.
## See docs/explanation/health-cadence.md#asking-for-a-re-check.
if [[ "$refresh" -eq 1 ]]; then
    if [[ "${#args[@]}" -eq 0 ]]; then
        echo "ERROR: --refresh needs at least one node or nodelist -- nothing was queued." >&2
        echo "       bash health-check.sh --refresh node001 'node00[2-9]'" >&2
        exit 2
    fi
    ## Every other mode takes a glob and this one does not, so an unquoted
    ## `ink50*` arrives as a literal name. Checked over all the arguments before
    ## any sentinel is written, so a bad one does not queue half of a list.
    ## See docs/explanation/health-cadence.md#asking-for-a-re-check.
    for arg in "${args[@]}"; do
        [[ "$arg" != *[\*\?]* ]] && continue
        matched=""
        for dir in "$logs_dir"/*/; do
            node=$(basename "$dir")
            # shellcheck disable=SC2053  # $arg is the caller's glob
            [[ "$node" == $arg ]] && matched+="${matched:+,}$node"
        done
        echo "ERROR: --refresh takes node names and Slurm nodelists, not globs, and" >&2
        echo "       '$arg' reached it as a literal name -- nothing was queued. It" >&2
        echo "       writes a sentinel per node, so the set is spelled out -- by a" >&2
        echo "       tool that expands one, or as a quoted nodeset:" >&2
        ## Single-quoted: these are examples to read, not commands to run here.
        echo '           bash health-check.sh --refresh $(nodeset -e @IDLE)' >&2
        echo '           bash health-check.sh --refresh "$(sinfo -h -t idle -o %N)"' >&2
        if [[ -n "$matched" ]]; then
            n_matched=$(count_list "$matched")
            echo "       $n_matched $(plural "$n_matched") under $logs_dir match it, as a" >&2
            echo "       nodeset -- quoted, or the shell expands the brackets:" >&2
            print_wrapped "           bash health-check.sh --refresh " \
                "'$(compress "$matched")'" >&2
        else
            echo "       Nothing under $logs_dir matches it either --" >&2
            echo "       bash health-check.sh --explain '$arg' lists what does." >&2
        fi
        exit 2
    done
    for arg in "${args[@]}"; do
        while IFS= read -r node; do
            [[ -z "$node" ]] && continue
            if [[ -d "$logs_dir/$node" ]]; then
                if touch "$logs_dir/$node/refresh" 2>/dev/null; then
                    ## The sentinel is consumed by the node, so queueing one on a
                    ## node that has stopped cycling succeeds and does nothing.
                    if heartbeat_stale "$results_dir" "$node"; then
                        echo "Refresh queued for $node -- but it has not cycled in ${HEARTBEAT_STALE_MINUTES}m, so nothing there will pick it up. ./trigger-log.sh section 0."
                    else
                        echo "Refresh queued for $node"
                    fi
                else
                    echo "ERROR: cannot write $logs_dir/$node/refresh as $(id -un) -- $node will re-check on its own cadence instead." >&2
                fi
            else
                ## Nothing here can tell a node that has never checked from a
                ## name that is not a node, and only one of them ever cycles.
                echo "Nothing queued for $node: no $logs_dir/$node. If it is a node, its first agent cycle creates one and runs the checks; if it is a typo, nothing will."
            fi
        done < <(scontrol show hostnames "$arg" 2>/dev/null || echo "$arg")
    done
    exit 0
fi

## Above every mode below, all of which filter through node_selected. Built
## after the module load: a nodelist is expanded by scontrol.
## See docs/reference/scripts.md#the-node-filter.
node_filter_set "${args[@]}"

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
    not_cycling=0
    for dir in "$logs_dir"/*/; do
        node=$(basename "$dir")
        node_selected "$node" || continue
        ((shown++))
        if [[ -f "$dir/.last-check" ]]; then
            IFS=$'\t' read -r epoch outcome < "$dir/.last-check"
        else
            epoch=""; outcome=""
        fi
        ## A due time is a prediction about a node that is still cycling, so this
        ## is asked before the stamp is read rather than printed beside it.
        ## See docs/explanation/health-cadence.md#a-due-time-assumes-a-live-node.
        stale=0
        if heartbeat_stale "$results_dir" "$node"; then stale=1; ((not_cycling++)); fi
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
            due='next agent cycle'
            [[ "$stale" -eq 1 ]] && due='not cycling — no agent to run them'
            printf '%-28s %-20s %-8s %s\n' "$node" '(never)' '-' "$due"
            continue
        fi
        hours="$HEALTH_INTERVAL_HOURS"
        [[ "$outcome" == "failed" ]] && hours="$HEALTH_RETRY_INTERVAL_HOURS"
        if [[ -f "$dir/refresh" && "$stale" -eq 1 ]]; then
            due='refresh queued — not cycling, so nothing picks it up'
        elif [[ "$stale" -eq 1 ]]; then
            due='not cycling — no check re-runs here'
        elif [[ -f "$dir/refresh" ]]; then
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
        echo "No node under $logs_dir matches '$(filter_desc)' — the checks have never run on any of them." >&2
        exit 1
    fi
    echo
    report_unmatched
    echo "Why a run stopped:  tail results/<node>/health.log"
    [[ "$not_cycling" -gt 0 ]] &&
        echo "Not cycling:        $not_cycling of $shown node(s) have written no heartbeat in ${HEARTBEAT_STALE_MINUTES}m -- ./trigger-log.sh section 0"
    exit 0
fi

# How many entries each elided list shows before it collapses to a count. The
# default report stays a fixed size as the cluster grows; --summary and
# --drained are the complete lists, so nothing elides in either.
max_groups=6
max_checks=8
max_reasons=8
if [[ "$summary" -eq 1 || "$drained" -eq 1 ]]; then
    max_groups=100000; max_checks=100000; max_reasons=100000
fi

## Groups nodes whose <check> file is identical, largest group first.
## See docs/reference/scripts.md#--individual.
if [[ "$individual" -eq 1 ]]; then
    check="${args[0]}"
    if [[ -z "$check" ]]; then
        echo "ERROR: --individual needs a check name -- e.g. bash health-check.sh --individual ib-firmware" >&2
        exit 2
    fi
    ## The check name is args[0]; everything after it is the node filter.
    node_filter_set "${args[@]:1}"
    declare -A ind_nodes ind_path
    total_ind=0
    for dir in "$logs_dir"/*/; do
        node=$(basename "$dir")
        node_selected "$node" || continue
        f="$dir/$check"
        [[ -f "$f" ]] || continue
        hash=$(md5sum "$f" | cut -d' ' -f1)
        ind_nodes["$hash"]+="$node,"
        ind_path["$hash"]="${ind_path[$hash]:-$f}"
        ((total_ind++))
    done
    if [[ "$total_ind" -eq 0 ]]; then
        ## A node name in the check slot is the common miss, and it matches
        ## nothing rather than erroring. See docs/reference/scripts.md#--individual.
        if [[ -d "$logs_dir/$check" ]]; then
            echo "ERROR: '$check' is a node, and --individual takes a check name --" >&2
            echo "       one check across the fleet. For one node's checks:" >&2
            echo "           bash health-check.sh --diff $check" >&2
            echo "       For a check on that node:  bash health-check.sh -i <check> $check" >&2
            exit 2
        fi
        echo "No logs/<node>/$check found for '$(filter_desc)'" >&2
        exit 1
    fi
    printf '%s — %d %s\n\n' "$check" "$total_ind" "$(plural "$total_ind")"
    mapfile -t hashes < <(
        for hash in "${!ind_nodes[@]}"; do
            printf '%d %s\n' "$(count_list "${ind_nodes[$hash]%,}")" "$hash"
        done | sort -rn | awk '{print $2}'
    )
    for hash in "${hashes[@]}"; do
        nodes="${ind_nodes[$hash]%,}"
        count=$(count_list "$nodes")
        printf '%d %s\n' "$count" "$(plural "$count")"
        print_wrapped "  " "$(compress "$nodes")"
        cat "${ind_path[$hash]}"
        echo
    done
    report_unmatched
    exit 0
fi

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
declare -A known_check
if [[ -d "$valid_dir" ]]; then
    while IFS= read -r name; do
        is_not_a_check "$name" && continue
        known_check["$name"]=1
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
# Shared with overall_report.sh so the two cannot drift.
if [[ ! -f "$home/reason-map.sh" ]]; then
    echo "ERROR: $home/reason-map.sh is missing -- it carries the reason-to-check" >&2
    echo "       name mapping and without it every drain reason parses as text." >&2
    exit 1
fi
source "$home/reason-map.sh"

# Which nodes are failing, from the log files -- not from the drain reason.
# Shared with overall_report.sh. See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.
if [[ ! -f "$home/health-scan.sh" ]]; then
    echo "ERROR: $home/health-scan.sh is missing -- it carries the comparison" >&2
    echo "       every failure below is derived from." >&2
    exit 1
fi
## Declared here as well as in the library: nothing follows a `source` at lint
## time, so these would read as undefined at every use below.
declare -A health_fail_count health_fail_list health_node_state
declare -a no_baseline_checks health_scan_notes
source "$home/health-scan.sh"
health_scan

## One node against the baseline, check by check. Driven by the logs rather than
## by the drain reason, so a node Slurm was never told about still diffs.
## See docs/reference/scripts.md#--diff.
if [[ "$diff_mode" -eq 1 ]]; then
    if [[ "$have_baseline" -ne 1 ]]; then
        for line in "${health_scan_notes[@]}"; do
            print_wrapped "ERROR: " "$line" >&2
        done
        exit 1
    fi
    baseline_node=$(readlink "$valid_dir" 2>/dev/null)
    baseline_node="${baseline_node##*/}"

    declare -A diff_state diff_reason
    while IFS='|' read -r dnode dstate dreason; do
        [[ -z "$dnode" || -n "${diff_state[$dnode]}" ]] && continue
        diff_state["$dnode"]="$dstate"
        [[ "$dreason" != "none" ]] && diff_reason["$dnode"]="$dreason"
    done < <(sinfo -N -h -o '%N|%T|%E' 2>/dev/null)

    shown=0
    for dir in "$logs_dir"/*/; do
        node=$(basename "$dir")
        node_selected "$node" || continue
        ((shown++))

        ## The drain, when there is one, is context rather than the input: it is
        ## what Slurm was told, and the diff below is what is actually true.
        label="${diff_state[$node]:-unknown}"
        [[ -n "${diff_reason[$node]}" ]] && label+=": ${diff_reason[$node]}"
        printf '%s  (%s)\n' "$node" "$label"
        printf '  <  this node\n'
        printf '  >  baseline%s\n\n' "${baseline_node:+ ($baseline_node)}"

        if [[ "$all" -eq 1 ]]; then
            mapfile -t names < <(printf '%s\n' "${!gated_check[@]}" | sort)
        else
            mapfile -t names < <(tr ',' '\n' <<< "${health_fail_list[$node]}" | sort -u)
        fi

        differing=0
        matching=""
        for name in "${names[@]}"; do
            [[ -z "$name" ]] && continue
            node_file="$dir$name"
            base_file="$valid_dir/$name"
            if [[ ! -f "$node_file" ]]; then
                printf -- '--- %s\n    no logs/%s/%s — the check did not run here\n\n' \
                    "$name" "$node" "$name"
                ((differing++))
                continue
            fi
            out=$(diff "$node_file" "$base_file" 2>&1)
            if [[ -z "$out" ]]; then
                matching+="$name, "
                continue
            fi
            ((differing++))
            printf -- '--- %s\n' "$name"
            printf '%s\n\n' "$out"
        done

        printf '%d of %d %s differ\n' "$differing" "${#gated_check[@]}" \
            "$([[ "${#gated_check[@]}" -eq 1 ]] && echo check || echo checks)"
        [[ -n "$matching" ]] && print_wrapped "Matching:  " "${matching%, }"
        echo
    done

    if [[ "$shown" -eq 0 ]]; then
        echo "No node under $logs_dir matches '$(filter_desc)' — nothing to diff." >&2
        echo "       A node absent from logs/ has never run node_health.sh." >&2
        exit 1
    fi
    report_unmatched
    exit 0
fi

declare -A seen_node reason_nodes drain_nodes sig_nodes check_count
total=0 failing=0 other=0 passing=0 unchecked=0 undrained=0 stale=0 out=0
passing_nodes="" unchecked_nodes="" failing_nodes="" other_nodes=""

while IFS='|' read -r node state reason; do
    [[ -z "$node" ]] && continue
    # sinfo -N lists a node once per partition it belongs to.
    [[ -n "${seen_node[$node]}" ]] && continue
    seen_node["$node"]=1

    node_selected "$node" || continue
    [[ "$reason" == "none" ]] && reason=""
    ((total++))

    # The label this node's drain carries in both groupings below. Empty for a
    # node that is in the queue, whatever the health verdict says about it.
    drain_key=""
    case "$state" in
        *down*|*drain*|*fail*|*unk*|*error*)
            drain_key="$state|${reason:-(no reason recorded)}" ;;
        *)  [[ -n "$reason" ]] && drain_key="$state|$reason" ;;
    esac

    # The logs decide, so a failing node lands here whether or not Slurm was
    # told about it. A drain it also carries is not printed twice.
    if [[ -n "${health_fail_count[$node]}" ]]; then
        ((failing++))
        failing_nodes+="$node,"
        health_node_state["$node"]="$state"
        if [[ -n "$drain_key" ]]; then
            ((out++)); drain_nodes["$drain_key"]+="$node,"
        else
            ((undrained++))
        fi
        # Sorted, so the same checks in a different order land in the same group.
        sig=$(tr ',' '\n' <<< "${health_fail_list[$node]}" | sort | tr '\n' ' ')
        sig="${sig% }"
        sig_nodes["$sig"]+="$node,"
        for name in $sig; do
            (( check_count["$name"]++ ))
        done
        continue
    fi

    if [[ -n "$drain_key" ]]; then
        # A health drain over logs that now match: the node was repaired and
        # nothing has resumed it. See docs/how-to/manage-drains.md#a-drain-the-logs-no-longer-support.
        for raw in $(canonicalize_reason "$reason"); do
            [[ -n "${known_check[$(resolve_token "$raw")]}" ]] || continue
            drain_key="${drain_key%%|*}|(logs now match) $reason"
            ((stale++))
            break
        done
        ((other++)); ((out++))
        other_nodes+="$node,"
        reason_nodes["$drain_key"]+="$node,"
        drain_nodes["$drain_key"]+="$node,"
        continue
    fi

    # In the queue and failing nothing: a never-checked node is not a passing
    # one. See docs/reference/scripts.md#--summary.
    if [[ -d "$logs_dir/$node" ]]; then
        ((passing++)); passing_nodes+="$node,"
    else
        ((unchecked++)); unchecked_nodes+="$node,"
    fi
done < <(sinfo -N -h -o '%N|%T|%E' 2>/dev/null)

if [[ "$total" -eq 0 ]]; then
    echo "No nodes match '$(filter_desc)'" >&2
    exit 1
fi

report_unmatched

# --drained: `sinfo -R` grouped. One line per distinct reason rather than one
# per node, because a rack powered off by CMDaemon is one event and reads as
# eighteen. Nothing else is printed -- this answers "what is out of the queue",
# not "what is broken". See docs/reference/scripts.md#--drained.
if [[ "$drained" -eq 1 ]]; then
    if [[ "$out" -eq 0 ]]; then
        echo "Nothing drained — all $total $(plural "$total") are in the queue"
        exit 0
    fi
    printf 'DRAINED — %d of %d %s\n\n' "$out" "$total" "$(plural "$total")"
    mapfile -t reasons < <(
        for key in "${!drain_nodes[@]}"; do
            printf '%s|%s\n' "$(count_list "${drain_nodes[$key]%,}")" "$key"
        done | sort -t'|' -k1,1nr -k2,2
    )
    for entry in "${reasons[@]}"; do
        count="${entry%%|*}"
        key="${entry#*|}"
        printf '  %-14s %-44s %4d %s\n' \
            "${key%%|*}" "${key#*|}" "$count" "$(plural "$count")"
        print_wrapped "      " "$(compress "${drain_nodes[$key]%,}")"
    done
    echo
    [[ "$stale" -gt 0 ]] &&
        echo "Marked lines are drains nothing supports any more — the checks pass now."
    echo "Why a node failed:  bash health-check.sh --diff <node>"
    echo "Resume by hand:     scontrol update NodeName=<node|nodelist> State=RESUME"
    exit 0
fi

# Nothing to compare against reads exactly like a healthy cluster, so the
# scan's own notes lead.
for line in "${health_scan_notes[@]}"; do
    print_wrapped "WARNING: " "$line"
    echo
done

# Paused means nothing re-runs, so this is a snapshot of whatever was true when
# the pause went on. See docs/how-to/pause-and-resume.md.
if setting_enabled "$PAUSE_HEALTH_CHECKS"; then
    echo "NOTE: PAUSE_HEALTH_CHECKS=$PAUSE_HEALTH_CHECKS in ${SETTINGS_FILE##*/}"
    echo "      node_health.sh is not running on any node, so nothing below can change"
    echo "      and a --refresh request will not be picked up until this is set"
    echo "      back to no."
    echo
fi

# The failures below are read from the logs, so drains being off no longer
# hides them -- but nothing was taken out of the queue either.
# See docs/how-to/manage-drains.md.
if ! setting_enabled "$DRAIN_AFTER_FAILED_HEALTH_CHECK" && [[ "$undrained" -gt 0 ]]; then
    echo "NOTE: DRAIN_AFTER_FAILED_HEALTH_CHECK=$DRAIN_AFTER_FAILED_HEALTH_CHECK in ${SETTINGS_FILE##*/}"
    echo "      No drain was set, so jobs are still being scheduled onto $undrained of the"
    echo "      $failing failing $(plural "$failing") below."
    echo
fi

# The grouped report below says what to fix, and nothing about the rest.
printf '%d %s — %d failing, %d passing, %d never checked, %d other %s\n\n' \
    "$total" "$(plural "$total")" "$failing" "$passing" "$unchecked" "$other" \
    "$([[ "$other" -eq 1 ]] && echo drain || echo drains)"

# --summary: the HEALTH block overall_report.sh prints, from the same numbers.
# See docs/reference/scripts.md#--summary.
if [[ "$summary" -eq 1 ]]; then
    health_section "$max_checks" "${unchecked_nodes%,}" --summary "$by_state"
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
        printf '... %d more %s covering %d %s — rerun with --summary\n\n' \
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

# Never compared, so neither passing nor above: the fix is a new baseline.
if [[ "${#no_baseline_checks[@]}" -gt 0 ]]; then
    n_missing="${#no_baseline_checks[@]}"
    echo "No baseline in $valid_dir — $n_missing $([[ "$n_missing" -eq 1 ]] && echo check || echo checks) can never pass:"
    print_wrapped "  " "$(elide "$(printf '%s\n' "${no_baseline_checks[@]}" | sort | paste -sd',' - | sed 's/,/, /g')" "$max_checks")"
    echo
fi

# Grouped by reason, not by node: eighteen racks powered off by CMDaemon is one
# line, and stays one line however many racks get added.
if [[ "$other" -gt 0 ]]; then
    echo "Not failing any check — $other drained $(plural "$other") (operator, the job sequencer,"
    echo "or a health drain over logs that now match — those are marked):"
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
        printf '  ... %d more %s covering %d %s — rerun with --drained\n' \
            "$(( ${#reasons[@]} - shown ))" \
            "$([[ $(( ${#reasons[@]} - shown )) -eq 1 ]] && echo reason || echo reasons)" \
            "$hidden" "$(plural "$hidden")"
    fi
    [[ "$stale" -gt 0 ]] &&
        echo "  Marked lines are drains nothing supports any more — the checks pass now."
    echo
fi

if [[ "$failing" -gt 0 ]]; then
    # One node per pattern is enough to diff -- the rest failed the same checks,
    # and 60 copies of one diff buries the answer.
    first_sig="${groups[0]#*|}"
    first_node="${sig_nodes[$first_sig]%%,*}"
    echo "Why a node failed:  bash health-check.sh --diff $first_node"
    [[ "${#groups[@]}" -gt 1 ]] && echo "                    (one node from pattern 1; each pattern needs its own diff)"
    echo "Per check, in full: bash health-check.sh --summary"
    echo "Re-run the checks:  bash health-check.sh --refresh <node|nodelist>"
fi
[[ "$out" -gt 0 ]] &&
    echo "Everything drained: bash health-check.sh --drained"

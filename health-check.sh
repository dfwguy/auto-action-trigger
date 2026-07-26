#!/bin/bash
#
# Usage: health-check.sh [pattern]
#
#   pattern  optional node-name filter. A bare string matches every node whose
#            name starts with it, so a rack prefix (dh01-rack01) covers the
#            whole rack. Shell globs (dh01-rack0[12]*, *node05) are honored as
#            written, so an explicit pattern can match anywhere in the name.
#            With no pattern, every node Slurm knows about is reported.
#
# Cluster-wide summary of health-check failures, pivoted on the check rather
# than the node: nine nodes failing "bios" is one BIOS problem with one fix, and
# listing it per-node reads as nine separate incidents.
#
# node_health.sh drains a node with the names of the checks that mismatched the
# baseline, so the Slurm reason field is the source of truth here -- no node is
# contacted and nothing is re-run. Use node-health-refresh.sh to re-run checks
# and sync-check.sh to see the actual diff for a node named below.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logs_dir="$home/logs"
valid_dir="$home/valid-config/default"

if ! command -v sinfo &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

pattern="$1"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

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
# Rewrite the multi-word ones before tokenizing; single-token renames are handled
# per token below.
canonicalize_reason() {
    local r="$1"
    r="${r//Check BIOS/bios}"
    r="${r//Check OS/os}"
    r="${r//enroot missing/enroot}"
    printf '%s' "$r"
}

resolve_token() {
    case "$1" in
        cuuid) printf 'nvidia-smi-cuuid' ;;
        *)     printf '%s' "$1"          ;;
    esac
}

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

declare -A seen_node check_nodes node_checks other_state other_reason
total=0 failing=0 other=0

while IFS='|' read -r node state reason; do
    [[ -z "$node" ]] && continue
    # sinfo -N lists a node once per partition it belongs to.
    [[ -n "${seen_node[$node]}" ]] && continue
    seen_node["$node"]=1

    [[ "$node" == $pattern ]] || continue
    ((total++))

    [[ -z "$reason" || "$reason" == "none" ]] && continue

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
        other_state["$node"]="$state"
        other_reason["$node"]="$reason"
        continue
    fi

    ((failing++))
    node_checks["$node"]="${matched% }"
    for name in $matched; do
        check_nodes["$name"]+="$node,"
    done
done < <(sinfo -N -h -o '%N|%T|%E' 2>/dev/null)

if [[ "$total" -eq 0 ]]; then
    echo "No nodes match '${1:-*}'" >&2
    exit 1
fi

if [[ "$failing" -eq 0 ]]; then
    echo "No failed health checks — $total $(plural "$total") checked"
else
    echo "FAILED HEALTH CHECKS — $failing of $total $(plural "$total")"
    echo
    # Most-common check first: that ordering puts the one fix that clears the
    # most nodes at the top.
    while IFS='|' read -r count name; do
        printf '%-24s %4d %-6s %s\n' \
            "$name" "$count" "$(plural "$count")" \
            "$(compress "${check_nodes[$name]%,}")"
    done < <(
        for name in "${!check_nodes[@]}"; do
            list="${check_nodes[$name]%,}"
            echo "$(tr -cd ',' <<< "$list" | wc -c | awk '{print $1+1}')|$name"
        done | sort -t'|' -k1,1nr -k2,2
    )
fi

multi=""
for node in "${!node_checks[@]}"; do
    [[ "${node_checks[$node]}" == *" "* ]] && multi+="$node"$'\n'
done
if [[ -n "$multi" ]]; then
    echo
    echo "Nodes failing more than one check:"
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        printf '  %-28s %s\n' "$node" "${node_checks[$node]// /, }"
    done < <(sort <<< "$multi")
fi

# A check with log output but no baseline entry can never pass: node_health.sh
# diffs against a file that is not there. Worth calling out separately -- the fix
# is a new baseline, not anything on the node.
missing=""
for name in "${!check_nodes[@]}"; do
    [[ -n "${baseline_has[$name]}" ]] || missing+="$name"$'\n'
done
if [[ -n "$missing" ]]; then
    echo
    echo "No baseline in $valid_dir (these can never pass):"
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        printf '  %s\n' "$name"
    done < <(sort <<< "$missing")
fi

if [[ "$other" -gt 0 ]]; then
    echo
    echo "Not health drains — $other $(plural "$other") (operator, or the job sequencer):"
    for node in $(printf '%s\n' "${!other_reason[@]}" | sort); do
        reason="${other_reason[$node]}"
        [[ "${#reason}" -gt 58 ]] && reason="${reason:0:55}..."
        printf '  %-28s %-14s %s\n' "$node" "${other_state[$node]}" "$reason"
    done
fi

if [[ "$failing" -gt 0 ]]; then
    echo
    echo "Why a node failed:  bash sync-check.sh \"$(compress "$(printf '%s,' "${!node_checks[@]}" | sed 's/,$//')")\""
    echo "Re-run the checks:  bash node-health-refresh.sh <node|nodelist>"
fi

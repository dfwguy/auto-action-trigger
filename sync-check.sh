#!/bin/bash
#
# Usage: sync-check.sh [--all] <node|nodelist>
#
#   --all    diff every check, not just the ones named in the drain reason.
#
# Shows why a node was drained: for each check named in its Slurm drain reason,
# diff that node's log output against the baseline.
#
# Read the diff direction carefully -- it is the thing most likely to be
# misread, and reading it backwards turns a bad baseline into 60 bad nodes:
#
#   <  is THIS NODE
#   >  is THE BASELINE (valid-config/default)
#
# So "< 0" against "> 228" means the node reports 0 and the baseline reports
# 228, and it is the baseline that needs looking at.
#
# With no argument, falls back to $SLURM_JOB_NODELIST so this can be run from
# inside a job.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logs_dir="$home/logs"
valid_dir="$home/valid-config/default"

if [[ ! -f "$home/reason-map.sh" ]]; then
    echo "ERROR: $home/reason-map.sh is missing -- it carries the reason-to-check" >&2
    echo "       name mapping and without it every drain reason parses as text." >&2
    exit 1
fi
source "$home/reason-map.sh"

all=0
args=()
for arg in "$@"; do
    case "$arg" in
        --all|-a)  all=1 ;;
        -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)         args+=("$arg") ;;
    esac
done

if ! command -v scontrol &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

NODELIST="${args[0]:-$SLURM_JOB_NODELIST}"
if [[ -z "$NODELIST" ]]; then
    echo "ERROR: no nodelist. Pass one as an argument or run inside a Slurm job." >&2
    exit 1
fi

if [[ ! -d "$valid_dir" ]]; then
    echo "ERROR: no baseline — $valid_dir does not resolve" >&2
    [[ -L "$valid_dir" ]] && echo "       points at $(readlink "$valid_dir"), which does not exist" >&2
    echo "       There is nothing to diff against. Run set-valid-default.sh first." >&2
    exit 1
fi

# Files node_health.sh writes into logs/<node>/ that are not checks.
is_not_a_check() {
    case "$1" in
        refresh|script-env) return 0 ;;
        *)                  return 1 ;;
    esac
}

# The set of real check names, taken from the baseline. A reason token that is
# not one of these is free text a check dragged in, not a missing file.
declare -A known_check
while IFS= read -r name; do
    is_not_a_check "$name" && continue
    known_check["$name"]=1
done < <(find -L "$valid_dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)

baseline_node=$(readlink "$valid_dir" 2>/dev/null)
baseline_node="${baseline_node##*/}"

while IFS='|' read -r node reason; do
    [[ -z "$node" ]] && continue

    echo "================================================================"
    echo "$node"
    echo "  <  $node"
    echo "  >  baseline${baseline_node:+ ($baseline_node)}"
    echo "================================================================"

    if [[ ! -d "$logs_dir/$node" ]]; then
        echo "  no logs/$node — this node has never run node_health.sh"
        echo
        continue
    fi

    # Which checks to diff.
    checks=""
    if [[ "$all" -eq 1 ]]; then
        checks=$(printf '%s\n' "${!known_check[@]}" | sort | tr '\n' ' ')
    else
        unknown=""
        for raw in $(canonicalize_reason "$reason"); do
            name=$(resolve_token "$raw")
            if [[ -z "${known_check[$name]}" ]]; then
                # Free text from a check that carries its own output into the
                # reason (dmesg-xid does). Note it once; do not try to diff it.
                [[ " $unknown " == *" $raw "* ]] || unknown+="$raw "
                continue
            fi
            [[ " $checks " == *" $name "* ]] && continue
            checks+="$name "
        done
    fi

    if [[ -z "$checks" ]]; then
        echo "  no checks named in the drain reason — not a node_health.sh drain"
        [[ -n "$reason" ]] && echo "  reason: $reason"
        echo
        continue
    fi

    differing=0
    matching=""
    for name in $checks; do
        node_file="$logs_dir/$node/$name"
        base_file="$valid_dir/$name"
        if [[ ! -f "$node_file" ]]; then
            printf -- '--- %s\n    no logs/%s/%s — the check did not run on this node\n\n' \
                "$name" "$node" "$name"
            ((differing++))
            continue
        fi
        out=$(diff "$node_file" "$base_file" 2>&1)
        if [[ -z "$out" ]]; then
            # Matches the baseline. The drain reason named it, so the reason is
            # older than either the log or the baseline -- worth saying, but not
            # worth a screen of blank sections.
            matching+="$name, "
            continue
        fi
        ((differing++))
        printf -- '--- %s\n' "$name"
        printf '%s\n\n' "$out"
    done

    printf '%d differing\n' "$differing"
    if [[ -n "$matching" ]]; then
        echo
        if [[ "$all" -eq 1 ]]; then
            echo "Matching the baseline:"
            echo "  ${matching%, }"
        else
            echo "Named in the drain reason but now matching the baseline:"
            echo "  ${matching%, }"
            echo "  The reason predates the current logs or baseline. Re-run the checks:"
            echo "      bash node-health-refresh.sh $node"
        fi
    fi
    if [[ -n "$unknown" ]]; then
        echo
        echo "Not check names (free text carried into the reason): ${unknown% }"
    fi
    echo
done < <(
    scontrol show node="$NODELIST" 2>/dev/null \
    | awk -F= '/NodeName=/{n=$2; sub(/ .*/,"",n)}
               /Reason=/{r=$2; sub(/ \[.*/,"",r); print n "|" r}'
)

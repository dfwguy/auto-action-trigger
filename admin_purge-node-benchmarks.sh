#!/bin/bash

if ! command -v scontrol &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
loc="$RESULTS_DIR"

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <node|nodelist> [<node|nodelist> ...]"
    echo "  Examples: $0 node001"
    echo "            $0 node00[1-18]"
    echo "            $0 node001 node002 node003"
    exit 1
fi

for arg in "$@"; do
    while IFS= read -r node; do
        # An empty node name collapses to "$loc/" and deletes every node's
        # results. See docs/how-to/reset-results.md.
        if [[ -z "${node//[[:space:]]/}" ]]; then
            echo "Skipping empty node name in '$arg'"
        elif [[ -d "$loc/$node" ]]; then
            echo "Purging $loc/$node"
            rm -rf "$loc/${node:?}"
        else
            echo "No results found for $node in $loc"
        fi
    done < <(scontrol show hostnames "$arg" 2>/dev/null || echo "$arg")
done

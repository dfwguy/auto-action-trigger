#!/bin/bash
#
# Usage: set-valid-default.sh <node>
#
# Promote one node's health log to the cluster baseline. Validate the node by
# hand first. See docs/how-to/add-a-health-check-set.md#set-the-baseline-first.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logs="$home/logs"
valid="$home/valid-config"

node="$1"

if [[ -z "$node" ]]; then
	echo "Usage: $0 <node>" >&2
	exit 1
fi

if [[ ! -d "$logs/$node" ]]; then
	echo "The node selected doesn't have a valid health log in $logs" >&2
	exit 1
fi

mkdir -p "$valid"

# -e is false for a dangling symlink, so test -L as well, or a stale `default`
# survives the rm and ln then fails with "File exists".
if [[ -e "$valid/default" || -L "$valid/default" ]]; then
	rm -f "$valid/default"
fi

# Replace rather than merge: a copy over an existing directory leaves behind
# checks node_health.sh no longer writes, which no node can then match.
rm -rf "${valid:?}/$node"
cp -r "$logs/$node" "$valid/"

# Relative, so the link resolves wherever the tree is unpacked.
ln -s "$node" "$valid/default"

echo "Baseline set to $node ($(find -L "$valid/default" -maxdepth 1 -type f | wc -l) checks)"
echo "Re-run the checks to clear the old failures:"
echo "    bash node-health-refresh.sh <node|nodelist>"

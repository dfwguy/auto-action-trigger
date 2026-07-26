#!/bin/bash
#
# Usage: set-valid-default.sh <node>
#
# Promote one node's health log to the cluster baseline. Every other node is
# diffed against it, so <node> defines "correct" for BIOS, OS, kernel params,
# IMEX, NVLink and everything else node_health.sh checks -- validate it by hand
# first.
#
#   /home/cmods/bringup/set-valid-default.sh ink50-dh01-h01-13
#
# The baseline is cluster-local and is never committed; see valid-config/.gitignore.

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

# -e is false for a dangling symlink, so test -L as well. A stale `default`
# pointing at a node from another cluster is the case that matters here: guard
# on -d alone and the rm is skipped, then ln fails with "File exists" and the
# baseline stays broken.
if [[ -e "$valid/default" || -L "$valid/default" ]]; then
	rm -f "$valid/default"
fi

# Replace rather than merge -- copying over an existing directory would leave
# behind checks that node_health.sh no longer writes, and those stale files
# become checks no node can ever match.
rm -rf "${valid:?}/$node"
cp -r "$logs/$node" "$valid/"

# Relative, so the link resolves the same wherever the tree is unpacked and can
# never name another machine's path.
ln -s "$node" "$valid/default"

echo "Baseline set to $node ($(find -L "$valid/default" -maxdepth 1 -type f | wc -l) checks)"
echo "Re-run the checks to clear the old failures:"
echo "    bash node-health-refresh.sh <node|nodelist>"

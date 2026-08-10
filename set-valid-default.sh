#!/bin/bash
#
# Usage: set-valid-default.sh <node>
#
# Promote one node's health log to the cluster baseline. Validate the node by
# hand first. See docs/how-to/add-a-health-check-set.md#set-the-baseline-first.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
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

# A copy, never a pointer -- docs/explanation/health-cadence.md#the-golden-baseline.
rm -f "$valid/$node/refresh" "$valid/$node/.last-check"

# Every informational log, by the property and not by name -- nothing diffs one,
# and the count below is the gated set. docs/explanation/node-inventory.md#it-is-not-a-baseline.
while IFS= read -r f; do
	name="${f##*/}"; name="${name%.sh}"; name="${name#*-}"
	rm -f "$valid/$node/$name"
done < <(awk 'FNR <= 10 && /^# informational: *yes/ { hit[FILENAME] = 1 }
              END { for (f in hit) print f }' "$HEALTHCHECKS_DIR"/[0-9]*.sh 2>/dev/null)

# Relative, so the link resolves wherever the tree is unpacked.
ln -s "$node" "$valid/default"

echo "Baseline set to $node ($(find -L "$valid/default" -maxdepth 1 -type f | wc -l) checks)"
echo "Re-run the checks to clear the old failures:"
echo "    bash health-check.sh --refresh <node|nodelist>"

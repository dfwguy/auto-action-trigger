#!/bin/bash
#
# Usage: admin_set-baseline.sh <node>
#
# Promote one node's health log to the cluster baseline. Validate the node by
# hand first. See docs/how-to/add-a-health-check-set.md#set-the-baseline-first.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$home/settings.sh"
# health_check_names: the gated set, defined once for the scan and the baseline.
source "$home/health-scan.sh"
logs="$HEALTH_LOG_DIR"
valid="$VALID_CONFIG_DIR"

node="$1"

if [[ -z "$node" ]]; then
	echo "Usage: $0 <node>" >&2
	exit 1
fi

if [[ ! -d "$logs/$node" ]]; then
	echo "The node selected doesn't have a valid health log in $logs" >&2
	exit 1
fi

# The baseline holds the gated checks and nothing else. Copying the directory
# and deleting what is not a check lost to every file nobody listed: the
# agent's own service.log sits beside the check output, and it became a
# baseline "check" that no other node's log could ever match.
# docs/explanation/node-inventory.md#it-is-not-a-baseline
mapfile -t checks < <(health_check_names)
if [[ ${#checks[@]} -eq 0 ]]; then
	echo "No check files under $HEALTHCHECKS_DIR -- a baseline of nothing would pass every node." >&2
	echo "Check HEALTHCHECKS in SETTINGS; the baseline was left as it was." >&2
	exit 1
fi

# A timed-out check is a hang, not a result: promoting it would pass every node
# that hangs the same way. docs/explanation/health-cadence.md#a-check-that-does-not-return
timed_out=()
for name in "${checks[@]}"; do
	if [[ -f "$logs/$node/$name" ]] && grep -qxF "$HEALTH_TIMEOUT_LINE" "$logs/$node/$name"; then
		timed_out+=("$name")
	fi
done
if [[ ${#timed_out[@]} -gt 0 ]]; then
	echo "$node's log for ${timed_out[*]} is a timeout, not a result: the check was killed before it finished." >&2
	echo "Fix what hung, or raise HEALTH_CHECK_TIMEOUT_SECONDS; the baseline was left as it was." >&2
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
# A copy, never a pointer -- docs/explanation/health-cadence.md#the-golden-baseline.
rm -rf "${valid:?}/$node"
mkdir -p "$valid/$node"
missing=()
for name in "${checks[@]}"; do
	if [[ -f "$logs/$node/$name" ]]; then
		cp -p "$logs/$node/$name" "$valid/$node/$name"
	else
		missing+=("$name")
	fi
done

# Relative, so the link resolves wherever the tree is unpacked.
ln -s "$node" "$valid/default"

echo "Baseline set to $node ($(find -L "$valid/default" -maxdepth 1 -type f | wc -l) checks)"
if [[ ${#missing[@]} -gt 0 ]]; then
	echo "WARNING: $node has no output for ${#missing[@]} gated check(s), which therefore have no" >&2
	echo "         baseline and can never pass: ${missing[*]}" >&2
	echo "         Run the checks on $node (report_health.sh --refresh $node) and set the baseline again." >&2
fi
echo "Re-run the checks to clear the old failures:"
echo "    bash report_health.sh --refresh <node|nodelist>"

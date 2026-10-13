#!/bin/bash
# Checks what admin_set-baseline.sh promotes: the gated checks of one node, by
# name, and nothing else from that node's log directory.
#
# The directory holds more than check output -- the health trace, the cadence
# stamp, the refresh marker, and the agent's own service.log. The earlier copy
# took the directory and deleted a list of names, so every file nobody listed
# (service.log) arrived in the baseline as a "check" no other node could match.
# The real script is run against a stub tree, not a copy of its logic.
# See docs/explanation/node-inventory.md#it-is-not-a-baseline.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        printf 'ok       %-50s %s\n' "$label" "$want"
    else
        printf 'FAILED   %-50s wanted [%s] in:\n%s\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}
same() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        printf 'ok       %-50s %s\n' "$label" "$want"
    else
        printf 'FAILED   %-50s wanted [%s], got [%s]\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}

for f in settings.sh health-scan.sh admin_set-baseline.sh; do
    cp "$home/$f" "$work/$f"
done
printf 'HEALTHCHECKS=checks\nJOB_USER=%s\n' "$(id -un)" > "$work/SETTINGS"

## Three gated checks, one informational.
mkdir -p "$work/health-checks/checks"
for c in 10-alpha 20-beta 30-gamma; do
    printf '#!/bin/bash\n# banner: b\n' > "$work/health-checks/checks/$c.sh"
done
printf '#!/bin/bash\n# banner: b\n# informational: yes\n' > "$work/health-checks/checks/40-nodeinfo.sh"

## node01's log directory as the agent leaves it: the check output, plus
## everything else that lives beside it.
logs="$work/logs/node01"
mkdir -p "$logs"
for c in alpha beta gamma nodeinfo; do printf 'b\n%s output\n' "$c" > "$logs/$c"; done
printf 'NODE-AGENT cycle\n'  > "$logs/service.log"
printf 'trace\n'             > "$logs/health.log"
printf 'oops\n'              > "$logs/stderr.log"
printf '%s\tclean\n' "$(date +%s)" > "$logs/.last-check"
: > "$logs/refresh"
printf 'PATH=/x\n'           > "$logs/script-env"

run() { ( cd "$work" && BRINGUP_DATA="$work" bash admin_set-baseline.sh "$@" 2>&1 ); }

out=$(run node01)
valid="$work/valid-config"

same "the baseline holds exactly the gated checks" \
    "alpha beta gamma" "$(find "$valid/node01" -type f -printf '%f\n' | sort | paste -sd' ' -)"
check "the count is the gated set" "Baseline set to node01 (3 checks)" "$out"
same "the agent's service.log stays out" "" "$(find "$valid" -name service.log)"
same "nor any informational check" "" "$(find "$valid" -name nodeinfo)"
same "a check keeps its content" "$(cat "$logs/beta")" "$(cat "$valid/node01/beta")"
same "default points at the copy, relatively" "node01" "$(readlink "$valid/default")"
check "the node's own log is left alone" "NODE-AGENT cycle" "$(cat "$logs/service.log")"

## A gated check the node never wrote cannot be baselined, and every node would
## then fail it forever -- say so instead of promoting a short baseline quietly.
printf '#!/bin/bash\n# banner: b\n' > "$work/health-checks/checks/50-delta.sh"
out=$(run node01)
check "a check the node never ran is named" "no output for 1 gated check(s)" "$out"
check "and which one" "can never pass: delta" "$out"
same "the rest is still promoted" "alpha beta gamma" \
    "$(find "$valid/node01" -type f -printf '%f\n' | sort | paste -sd' ' -)"
rm -f "$work/health-checks/checks/50-delta.sh"

## Promoting again replaces rather than merges: a file left from an older
## baseline would be a check node_health.sh no longer writes.
printf 'stale\n' > "$valid/node01/retired"
run node01 > /dev/null
same "a re-run leaves no stale file behind" "" "$(find "$valid/node01" -name retired)"

## With no check files the gated set is empty, and a baseline of nothing would
## pass every node: refuse, and leave the existing baseline where it was.
mv "$work/health-checks/checks" "$work/health-checks/elsewhere"
mkdir -p "$work/health-checks/checks"
out=$(run node01); rc=$?
same "no checks is refused" "1" "$rc"
check "with the reason" "a baseline of nothing would pass every node" "$out"
same "the existing baseline is kept" "node01" "$(readlink "$valid/default")"
same "and still holds its checks" "alpha beta gamma" \
    "$(find "$valid/node01" -type f -printf '%f\n' | sort | paste -sd' ' -)"

out=$(run nosuchnode); rc=$?
same "an unknown node is refused" "1" "$rc"
check "with the reason" "doesn't have a valid health log" "$out"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed"
    exit 1
fi

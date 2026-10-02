#!/bin/bash
#
# Checks health-scan.sh, which decides which nodes are failing for both
# report_health.sh and report_overall.sh. Everything here is a way of getting
# that answer wrong quietly: an informational check counted as a fault takes a
# rack out on paper, a check with no baseline entry read as a pass hides the
# missing baseline, and a node filter that misses turns a rack report into a
# fleet report.
#
# The real library is sourced against a stub tree, not a copy of its logic.
# See docs/explanation/reading-the-whole-fleet.md#health-read-from-the-files.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fails=0
check() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        printf 'ok       %-46s %s\n' "$label" "$got"
    else
        printf 'FAILED   %-46s wanted [%s] got [%s]\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}

## The tree: three gated checks, one informational, and `orphan` with no
## baseline entry -- a check added since the last admin_set-baseline.sh run.
mkdir -p "$work"/{checks,baseline,logs}
printf '#!/bin/bash\n# banner: b\n'                          > "$work/checks/10-alpha.sh"
printf '#!/bin/bash\n# banner: b\n'                          > "$work/checks/20-beta.sh"
printf '#!/bin/bash\n# banner: b\n'                          > "$work/checks/30-gamma.sh"
printf '#!/bin/bash\n# banner: b\n# informational: yes\n'    > "$work/checks/40-imex.sh"
printf '#!/bin/bash\n# banner: b\n'                          > "$work/checks/50-orphan.sh"
for c in alpha beta gamma imex; do printf 'b\ngood\n' > "$work/baseline/$c"; done

for n in node01 node02 node03; do
    mkdir -p "$work/logs/$n"
    for c in alpha beta gamma imex orphan; do printf 'b\ngood\n' > "$work/logs/$n/$c"; done
done
## node01 fails alpha and beta, node02 alpha only, node03 nothing that counts:
## its two mismatches are the informational check and the one with no baseline.
printf 'b\nBAD\n' > "$work/logs/node01/alpha"
printf 'b\nBAD\n' > "$work/logs/node01/beta"
printf 'b\nBAD\n' > "$work/logs/node02/alpha"
printf 'b\nBAD\n' > "$work/logs/node03/imex"
printf 'b\nBAD\n' > "$work/logs/node03/orphan"

## Sourced in a subshell per case, because health_scan is a one-shot: the
## arrays it fills are never cleared, so two runs in one shell would merge.
scan() {
    HEALTHCHECKS_DIR="$work/checks" logs_dir="$work/logs" valid_dir="$2" \
    bash -c '
        HEALTHCHECKS_DIR="$HEALTHCHECKS_DIR" logs_dir="$logs_dir" valid_dir="$valid_dir"
        source "$4"
        source "$1"
        node_filter_set "$2"
        health_scan
        eval "$3"' _ "$home/health-scan.sh" "$1" "$3" "$home/report-format.sh"
}

## ── The verdict, both ways round ──────────────────────────────────────────

check "failing nodes, not every node with a log" "node01 node02" \
    "$(scan '*' "$work/baseline" 'printf "%s\n" "${!health_fail_count[@]}" | sort | paste -sd" " -')"

check "the checks a node failed" "alpha,beta" \
    "$(scan '*' "$work/baseline" 'echo "${health_fail_list[node01]}"')"

check "how many it failed" "2" \
    "$(scan '*' "$work/baseline" 'echo "${health_fail_count[node01]}"')"

check "the nodes a check failed on" "node01,node02" \
    "$(scan '*' "$work/baseline" 'echo "${check_fail_nodes[alpha]}"')"

## An informational check is recorded and never drained on, so counting it here
## would report a rack's own IMEX configuration as a fault on every node in it.
check "an informational mismatch is not a failure" "" \
    "$(scan '*' "$work/baseline" 'echo "${check_fail_nodes[imex]}"')"

## No baseline entry means nothing to compare against, so it is neither a pass
## nor a failure -- and the fix is a new baseline, not the node.
check "a check with no baseline is not a failure" "" \
    "$(scan '*' "$work/baseline" 'echo "${check_fail_nodes[orphan]}"')"
check "it is named instead" "orphan" \
    "$(scan '*' "$work/baseline" 'printf "%s\n" "${no_baseline_checks[@]}"')"

## ── The node filter ───────────────────────────────────────────────────────
## Both aggregates, because they are built separately and only one of them
## being narrowed is a report whose header disagrees with its body.

check "the filter drops other nodes" "node01" \
    "$(scan 'node01*' "$work/baseline" 'printf "%s\n" "${!health_fail_count[@]}"')"
check "and narrows the per-check list too" "node01" \
    "$(scan 'node01*' "$work/baseline" 'echo "${check_fail_nodes[alpha]}"')"
check "a check left with no node is dropped" "" \
    "$(scan 'node02*' "$work/baseline" 'echo "${check_fail_nodes[beta]}"')"

## ── Nothing to compare against ────────────────────────────────────────────
## An empty report and a healthy cluster look identical, so this has to say so
## rather than return no failures.

check "a missing baseline reports no failures" "0" \
    "$(scan '*' "$work/nowhere" 'echo "${#health_fail_count[@]}"')"
check "and says why" "No baseline" \
    "$(scan '*' "$work/nowhere" 'echo "${health_scan_notes[0]}"' | cut -c1-11)"
check "have_baseline is the flag for it" "0" \
    "$(scan '*' "$work/nowhere" 'echo "$have_baseline"')"

## ── The elided render ─────────────────────────────────────────────────────
## health_section is what both reports print; the cap is what keeps it a fixed
## size as the cluster grows.

render() {
    HEALTHCHECKS_DIR="$work/checks" logs_dir="$work/logs" valid_dir="$work/baseline" \
    COLUMNS=100 bash -c '
        HEALTHCHECKS_DIR="$HEALTHCHECKS_DIR" logs_dir="$logs_dir" valid_dir="$valid_dir"
        source "$2"
        source "$1"
        health_scan
        health_section "$3" "$4"' _ "$home/health-scan.sh" "$home/report-format.sh" "$@"
}

check "every failing check is named" "2" \
    "$(render 8 "" | grep -cE '^    (alpha|beta) ')"
check "the cap collapses the tail" "1 more check" \
    "$(render 1 "" | sed -n 's/.*\.\.\. \([0-9]* more check\).*/\1/p')"
check "a never-checked node is listed apart" "node09" \
    "$(render 8 node09 | sed -n 's/^    \(node09\)$/\1/p')"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails failed"
    exit 1
fi

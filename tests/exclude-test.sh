#!/bin/bash
#
# Usage: tests/exclude-test.sh
#
# Checks the gate that keeps a host which is not a compute node out of the
# sweep and out of the reports.
#
# Both directions are silent failures, which is why this has a suite. A false
# positive retires a real node from the fleet and it reports nothing ever again;
# a false negative is the head node sitting in every report as a row of
# NOT_RUN. The detection is deliberately NOT `sinfo -N -n`, and the case that
# guards it is `busy controller is not a head node`.
#
# See docs/explanation/sequencing.md#a-host-that-is-not-a-compute-node.
#
# Builds its own tree in a temp directory. No cluster, no slurm, no network.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'ok       %-46s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-46s %s\n' "$1" "$2"; fail=$((fail + 1)); }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

## A stub on PATH ahead of the real one, so a developer machine that has
## systemctl is asked the fixture's question and not its own.
stubdir="$tmp/bin"
mkdir -p "$stubdir"
PATH="$stubdir:$PATH"

## What `systemctl list-unit-files slurmd.service slurmctld.service` prints on
## each kind of host. UNITS is read by the stub at call time.
stub_systemctl() {
    cat > "$stubdir/systemctl" <<'EOF'
#!/bin/bash
printf '%s' "$UNITS"
EOF
    chmod +x "$stubdir/systemctl"
}
stub_systemctl

HEADNODE='slurmctld.service enabled enabled'
COMPUTE='slurmd.service enabled enabled'
BOTH="$HEADNODE
$COMPUTE"

# ── The site's list ───────────────────────────────────────────────────────────

EXCLUDE_NODES=""
source "$home/settings.sh"

check_excluded() {
    local label="$1" want="$2" node="$3"
    EXCLUDE_NODES="$4"
    if node_excluded "$node"; then got=yes; else got=no; fi
    [[ "$got" == "$want" ]] &&
        ok "$label" "$node vs '$4' -> $got" ||
        bad "$label" "$node vs '$4' -> $got, want $want"
}

check_excluded "empty list excludes nothing"     no  nscale-hn1 ""
check_excluded "exact name"                      yes nscale-hn1 "nscale-hn1"
check_excluded "glob"                            yes nscale-hn1 "*-hn[0-9]"
check_excluded "second pattern in the list"      yes nscale-hn2 "nscale-hn1 nscale-hn2"
check_excluded "a compute node is not matched"   no  nscale-n01 "nscale-hn*"
## A prefix match here would take out every node in the rack.
check_excluded "no implicit trailing glob"       no  nscale-hn10 "nscale-hn1"
check_excluded "whitespace-only list"            no  nscale-hn1 "   "

## SC2034: read by node_excluded, which was sourced from settings.sh.
# shellcheck disable=SC2034
EXCLUDE_NODES=""

# ── Self-detection ────────────────────────────────────────────────────────────

check_self() {
    local label="$1" want="$2"
    UNITS="$3"
    export UNITS
    if node_self_excluded; then got=yes; else got=no; fi
    [[ "$got" == "$want" ]] &&
        ok "$label" "-> $got" ||
        bad "$label" "-> $got, want $want"
}

check_self "slurmctld and no slurmd is a head node" yes "$HEADNODE"
check_self "slurmd is a compute node"               no  "$COMPUTE"
check_self "both units installed"                   no  "$BOTH"
## The whole point: an empty answer is not an answer. sinfo returning nothing
## is what retired 981 real nodes, and this must not repeat it.
check_self "busy controller is not a head node"     no  ""

rm -f "$stubdir/systemctl"
check_self "no systemctl at all"                    no  "$HEADNODE"
stub_systemctl

# ── The marker the reports read ───────────────────────────────────────────────

mkdir -p "$tmp/results/node01" "$tmp/results/nscale-hn1"

node_out_of_reporting "$tmp/results" node01 &&
    bad "unmarked node is reported" "node01 excluded" ||
    ok  "unmarked node is reported" "node01"

node_mark_excluded "$tmp/results/nscale-hn1" "self-detected: test"
node_out_of_reporting "$tmp/results" nscale-hn1 &&
    ok  "a marked host is left out" "nscale-hn1" ||
    bad "a marked host is left out" "still reported"

grep -q 'self-detected: test' "$tmp/results/nscale-hn1/$NOT_COMPUTE_MARKER" &&
    ok  "the marker records the reason" "$NOT_COMPUTE_MARKER" ||
    bad "the marker records the reason" "file does not carry it"

## Self-correcting in one direction: a node wrongly marked comes back on its
## next normal cycle without anyone deleting a file by hand.
node_unmark_excluded "$tmp/results/nscale-hn1"
node_out_of_reporting "$tmp/results" nscale-hn1 &&
    bad "a cleared marker restores the host" "still excluded" ||
    ok  "a cleared marker restores the host" "nscale-hn1"

# ── End to end, through the two reports ───────────────────────────────────────
#
# A copy of the tree: these cases write SETTINGS and a results/, and must not
# touch the checkout.

cp -a "$home" "$tmp/tree" || exit 1
tree="$tmp/tree"
rm -rf "$tree/results" "$tree/SETTINGS"
F="$home/tests/fixtures"

for n in node01 nscale-hn1; do
    d="$tree/results/$n"
    mkdir -p "$d"
    cp "$F/dcgmi-r3__pass.txt" "$d/dcgmi-r1.txt"
done
node_mark_excluded "$tree/results/nscale-hn1" "self-detected: test"

printf 'BENCHMARKS="dcgmi-r1"\nEXCLUDE_NODES=""\n' > "$tree/SETTINGS"

report_case() {
    local label="$1" script="$2"
    local out err
    out=$("$tree/$script" 2>"$tmp/err"); err=$(cat "$tmp/err")

    if grep -q 'nscale-hn1' <<<"$out"; then
        bad "$label: no row for the marked host" "it is in the table"
    else
        ok  "$label: no row for the marked host" "nscale-hn1 absent"
    fi
    ## Dropped in silence, a missing row reads exactly like a node nobody
    ## registered. The NOTE is the whole difference.
    if grep -q 'nscale-hn1' <<<"$err"; then
        ok  "$label: says which hosts it left out" "named on stderr"
    else
        bad "$label: says which hosts it left out" "dropped silently"
    fi
    if grep -q 'node01' <<<"$out"; then
        ok  "$label: normal nodes still reported" "node01 present"
    else
        bad "$label: normal nodes still reported" "node01 missing"
    fi
}

report_case "status-check.sh" status-check.sh
report_case "daily-report.sh" daily-report.sh

## The same host excluded by the setting instead of the marker, with no marker
## on disk at all -- the two paths have to reach the same table.
node_unmark_excluded "$tree/results/nscale-hn1"
printf 'BENCHMARKS="dcgmi-r1"\nEXCLUDE_NODES="nscale-hn*"\n' > "$tree/SETTINGS"
report_case "EXCLUDE_NODES, status-check.sh" status-check.sh

## trigger-log.sh hides it like the rest, and is the one script that can still
## be asked -- its trigger.log is where the reason was written.
printf '2026-01-01 00:00:00 EXIT: nscale-hn1 runs slurmctld and has no slurmd\n' \
    > "$tree/results/nscale-hn1/trigger.log"
printf '2026-01-01 00:00:00 queue: bench=0 burnin=0\n' \
    > "$tree/results/node01/trigger.log"

if "$tree/trigger-log.sh" 2>&1 | grep -q 'skipped'; then
    ok  "trigger-log.sh skips it and says so" "NOTE printed"
else
    bad "trigger-log.sh skips it and says so" "no NOTE"
fi
if "$tree/trigger-log.sh" --include-excluded -t 20 nscale-hn1 2>&1 | grep -q 'no slurmd'; then
    ok  "--include-excluded reads it anyway" "trace reachable"
else
    bad "--include-excluded reads it anyway" "trace unreachable"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

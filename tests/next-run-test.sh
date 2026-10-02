#!/bin/bash
#
# Usage: tests/next-run-test.sh
#
# Checks the buckets check_next-run.sh puts nodes in: the retry window and its
# backoff, the health cadence and its two intervals, the three answers that are
# not times, and the order the groups come out in.
#
# The arithmetic is a second copy of what actions/launch_job.sh and
# actions/node_health.sh decide, and the failure mode is silent -- a report that
# says "within 4h" over a fleet that fires in ten minutes reads exactly like a
# correct one. So every case here pins a bucket against files whose ages this
# script chose.
#
# See docs/how-to/see-what-fires-next.md#how-the-buckets-are-chosen.
#
# Builds its own tree in a temp directory. No cluster, no slurm, no network.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'ok       %-46s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'FAIL     %-46s %s\n' "$1" "$2"; fail=$((fail + 1)); }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

## The scripts under test, not a copy of them: a copy is a second thing to keep
## in step. check_next-run.sh resolves its home from the path it was invoked by, so
## results/ and logs/ are the fixture's and everything else is the tree's.
for f in check_next-run.sh settings.sh fanout.sh verdict-scan.sh jobs parsers; do
    ln -s "$home/$f" "$tmp/$f"
done
mkdir -p "$tmp/results" "$tmp/logs"

## clubak's grouping, spelled `<nodes>|<line>` so one grep asserts both the
## bucket and which nodes share it. On PATH ahead of a real clubak, so a
## developer machine that has ClusterShell is asked this question and not its own.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/clubak" <<'EOF'
#!/bin/bash
sort | awk '{
    i = index($0, ": "); node = substr($0, 1, i - 1); line = substr($0, i + 2)
    if (line in g) { g[line] = g[line] "," node } else { g[line] = node; order[++k] = line }
} END { for (j = 1; j <= k; j++) printf "%s|%s\n", g[order[j]], order[j] }'
EOF
chmod 755 "$tmp/bin/clubak"
PATH="$tmp/bin:$PATH"
export FANOUT_TOOL=clush   ## clubak, never a real dshbak that happens to be here

settings() {
    cat > "$tmp/SETTINGS" <<EOF
BRINGUP_DATA=$tmp
BENCHMARKS="dcgmi-r3 nvbandwidth"
RUN_BURNIN=no
RETRY_INTERVAL_HOURS=1
RETRY_BACKOFF=${1:-yes}
RETRY_BACKOFF_MAX_HOURS=12
HEALTH_INTERVAL_HOURS=${2:-4}
HEALTH_RETRY_INTERVAL_HOURS=1
AGENT_INTERVAL_MINUTES=2
HEARTBEAT_STALE_MINUTES=10
RUN_JOBS=${3:-yes}
RUN_HEALTH_CHECKS=yes
EOF
}
settings

now=$(date +%s)
node() { mkdir -p "$tmp/results/$1" "$tmp/logs/$1"; touch "$tmp/results/$1/.heartbeat"; }
result() { cp "$home/tests/fixtures/$2" "$tmp/results/$1/$3"; touch -d "@$4" "$tmp/results/$1/$3"; }

## n01, n02 -- nothing has ever run here, so the first column is due now
node n01
node n02

## n03 -- one column passes, the other failed 10 minutes ago: the flat 1h window
node n03
result n03 dcgmi-r3__pass.txt      dcgmi-r3.txt    "$now"
result n03 nvbandwidth__unstable.txt nvbandwidth.txt "$((now - 600))"

## n04 -- the same, with three failures already archived beside it: 1h + 3h
node n04
result n04 dcgmi-r3__pass.txt      dcgmi-r3.txt    "$now"
result n04 nvbandwidth__unstable.txt nvbandwidth.txt "$((now - 600))"
for i in 1 2 3; do
    cp "$home/tests/fixtures/nvbandwidth__unstable.txt" "$tmp/results/n04/nvbandwidth.fail$i.txt"
done

## n05 -- every column passes
node n05
result n05 dcgmi-r3__pass.txt   dcgmi-r3.txt    "$now"
result n05 nvbandwidth__good.txt nvbandwidth.txt "$now"

## n06 -- a job of ours is out
node n06
printf '12345\tallreduce\t1\t1\t%s\n' "$((now - 900))" > "$tmp/results/n06/.in-flight"

## n07 -- the timer here is not firing
node n07
touch -d "@$((now - 99999))" "$tmp/results/n07/.heartbeat"

## The health stamps: second field picks the interval.
printf '%s\tclean\n'  "$((now - 3600))" > "$tmp/logs/n03/.last-check"
printf '%s\tfailed\n' "$((now - 600))"  > "$tmp/logs/n04/.last-check"
touch "$tmp/logs/n05/refresh"
printf '%s\tclean\n'  "$((now - 100))"  > "$tmp/logs/n06/.last-check"

run() { SCAN_CACHE=0 bash "$tmp/check_next-run.sh" "$@" 2>"$tmp/err"; }

has() {
    local label="$1" want="$2" out="$3"
    grep -Fqx -- "$want" <<<"$out" && ok "$label" "$want" || bad "$label" "wanted [$want]"
}

# ── The benchmark buckets ─────────────────────────────────────────────────────

out=$(run --tests)

has "no result at all is due now"        'n01,n02|soon — dcgmi-r3'                 "$out"
has "a fresh failure waits out the hour" 'n03|within 1h — nvbandwidth'             "$out"
has "three archives widen it to 4h"      'n04|within 4h — nvbandwidth'             "$out"
has "every column passing is its own group" \
    'n05|nothing due — every benchmark passes here'                                "$out"
has "a job out is waiting, not a time"   'n06|waiting on allreduce run 1, out for 15m' "$out"
has "a stale heartbeat is not a time"    'n07|not cycling — no gate here is reached, so nothing fires' "$out"

## Soonest first, and the two that are not times outside the ordering: the fault
## at the top, the nodes with nothing owing at the bottom.
order=$(sed -n 's/^[^|]*|\(.*\)/\1/p' <<<"$out" | tr '\n' '/')
want='not cycling — no gate here is reached, so nothing fires/waiting on allreduce run 1, out for 15m/soon — dcgmi-r3/within 1h — nvbandwidth/within 4h — nvbandwidth/nothing due — every benchmark passes here/'
[[ "$order" == "$want" ]] &&
    ok "groups come out soonest first" "${order//\// }" ||
    bad "groups come out soonest first" "got [$order]"

grep -q 'HEALTH CHECKS' <<<"$out" &&
    bad "--tests prints one section" "the health section is there too" ||
    ok "--tests prints one section" "no health section"

# ── Backoff off ───────────────────────────────────────────────────────────────

settings no
out=$(run --tests)
has "RETRY_BACKOFF=no keeps the flat window" 'n03,n04|within 1h — nvbandwidth' "$out"
settings

# ── The health buckets ────────────────────────────────────────────────────────

out=$(run --healthchecks)

has "never checked is due now"        'n01,n02|soon — the checks have never run here' "$out"
has "a clean run waits out the 4h"    'n03|within 3h — last run clean, on the 4h interval' "$out"
has "a failed run is on the 1h retry" 'n04|within 1h — last run failed, on the 1h interval' "$out"
has "a queued refresh is due now"     'n05|soon — a refresh is queued here by hand' "$out"
has "the interval is counted from the stamp" \
    'n06|within 4h — last run clean, on the 4h interval'                                  "$out"

grep -q 'TESTS —' <<<"$out" &&
    bad "--healthchecks prints one section" "the benchmark section is there too" ||
    ok "--healthchecks prints one section" "no benchmark section"

# ── The cadence switched off ──────────────────────────────────────────────────

settings yes 0
out=$(run --healthchecks)
has "HEALTH_INTERVAL_HOURS=0 is nothing due" \
    'n03,n06|nothing due — the cadence is off, so only '"'"'report_health.sh --refresh'"'"' re-runs them' "$out"
settings

# ── A paused fleet says so, and not in the report ─────────────────────────────

settings yes 4 no
out=$(run --tests)
grep -q 'RUN_JOBS' "$tmp/err" &&
    ok "RUN_JOBS is named on stderr" "$(head -1 "$tmp/err")" ||
    bad "RUN_JOBS is named on stderr" "nothing on stderr"
grep -q 'RUN_JOBS' <<<"$out" &&
    bad "the note stays out of the node lists" "it is on stdout" ||
    ok "the note stays out of the node lists" "stdout is buckets only"
settings

# ── Both sections by default ──────────────────────────────────────────────────

out=$(run)
if grep -q 'TESTS —' <<<"$out" && grep -q 'HEALTH CHECKS' <<<"$out"; then
    ok "no flag prints both sections" "TESTS and HEALTH CHECKS"
else
    bad "no flag prints both sections" "one of them is missing"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

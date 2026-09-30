#!/bin/bash
#
# Checks the gates in actions/node_health.sh that decide whether the checks run
# at all: the cadence, the refresh sentinel, the pause, and the refusal to
# overwrite a baseline that points at this node's own log directory.
#
# Every one of them ends the cycle with `exit 0` and a trace line, so a mistake
# here is a fleet that has quietly stopped health-checking -- or, for the last
# one, a golden baseline that silently follows one node's drift.
# See docs/explanation/health-cadence.md.
#
# The real script is run against a stub tree, not a copy of its logic.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NODE=stub-node-01
export HOSTNAME="$NODE"

mkdir -p "$work"/{bin,health-checks/stub,valid-config,logs,results}
cp "$home/settings.sh" "$work/settings.sh"

## Slurm and the module system, stubbed. `sinfo` has to answer, or every run
## stops at the gate above the ones under test.
cat > "$work/bin/sinfo" <<'EOF'
#!/bin/bash
echo idle
EOF
cat > "$work/bin/scontrol" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$work/bin/sinfo" "$work/bin/scontrol"
mkdir -p "$work/etc/profile.d"

cat > "$work/health-checks/stub/10-alpha.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Alpha
echo alpha-value
EOF

mkdir -p "$work/valid-config/baseline"
printf '########INFO: Check Alpha\nalpha-value\n' > "$work/valid-config/baseline/alpha"
ln -sfn baseline "$work/valid-config/default"

settings() {
    cat > "$work/SETTINGS" <<EOF
HEALTHCHECKS=stub
JOB_USER=$(id -un)
BRINGUP_HOME=$work
BRINGUP_DATA=$work
EXCLUDE_NODES=""
$*
EOF
}

## The script sources /etc/profile.d/modules.sh by absolute path and shells out
## to `module`, neither of which exists here.
run() {
    NODE_HEALTH_HOME="$work" HOSTNAME="$NODE" PATH="$work/bin:$PATH" \
        bash -c 'source() { [[ "$1" == /etc/profile.d/modules.sh ]] && return 0; builtin source "$@"; }
                 module() { return 0; }
                 export -f module
                 . "$0" "$@"' "$home/actions/node_health.sh" --quiet "$@" 2>&1
}

fails=0
check() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        printf 'ok       %-46s\n' "$label"
    else
        printf 'FAILED   %-46s wanted [%s] in:\n%s\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}
## Three, not one: a run that reaches the end writes its finding and then the
## drain gate's line under it.
trace_tail() { tail -3 "$work/logs/$NODE/health.log" 2>/dev/null; }

settings 'HEALTH_INTERVAL_HOURS=4
HEALTH_RETRY_INTERVAL_HOURS=1'

## 1. No stamp: an upgraded tree must run once rather than wait for a sentinel.
saved_umask=$(umask)
umask 0077
run >/dev/null
umask "$saved_umask"
check "first run writes the stamp" "clean" "$(cat "$work/logs/$NODE/.last-check")"
check "first run wrote a log"      "alpha-value" "$(cat "$work/logs/$NODE/alpha")"
check "first run traced"           "every check matches" "$(trace_tail)"
check "shared log directory is group writable" "775" "$(stat -c %a "$work/logs/$NODE")"
check "shared check output is group writable"  "664" "$(stat -c %a "$work/logs/$NODE/alpha")"

## 2. Stamp is fresh: the ordinary quiet cycle, which must say why it stopped.
run >/dev/null
check "inside the interval, exits"  "EXIT: last run" "$(trace_tail)"
check "and names the next due time" "next due in"    "$(trace_tail)"

## 3. --force opens it.
run --force >/dev/null
check "--force re-runs" "every check matches" "$(trace_tail)"

## 4. The sentinel opens it, and is consumed.
touch "$work/logs/$NODE/refresh"
run >/dev/null
check "refresh re-runs" "every check matches" "$(trace_tail)"
if [[ -f "$work/logs/$NODE/refresh" ]]; then
    printf 'FAILED   %-46s sentinel survived the run\n' "refresh is consumed"
    fails=$((fails + 1))
else
    printf 'ok       %-46s\n' "refresh is consumed"
fi

## 5. A failing run takes the shorter interval. The stamp is backdated past the
## retry interval but not past the clean one, so only the right one re-runs.
cat > "$work/health-checks/stub/10-alpha.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Alpha
echo alpha-drifted
EOF
run --force >/dev/null
check "a mismatch is recorded as failed" "failed" "$(cat "$work/logs/$NODE/.last-check")"
check "and traced by name"               "differs from" "$(trace_tail)"

printf '%s\t%s\n' "$(( $(date +%s) - 2 * 3600 ))" failed > "$work/logs/$NODE/.last-check"
run >/dev/null
check "failed re-checks on the short interval" "differs from" "$(trace_tail)"

printf '%s\t%s\n' "$(( $(date +%s) - 2 * 3600 ))" clean > "$work/logs/$NODE/.last-check"
run >/dev/null
check "clean waits out the long interval" "EXIT: last run" "$(trace_tail)"

## 6. Both intervals 0 is the old behaviour, and is a real answer.
settings 'HEALTH_INTERVAL_HOURS=0
HEALTH_RETRY_INTERVAL_HOURS=0'
printf '%s\t%s\n' "$(( $(date +%s) - 99 * 3600 ))" clean > "$work/logs/$NODE/.last-check"
run >/dev/null
check "cadence off means never on its own" "the cadence is off" "$(trace_tail)"

## 7. The pause stops the run and holds the sentinel for after it.
settings 'HEALTH_INTERVAL_HOURS=4
RUN_HEALTH_CHECKS=no'
touch "$work/logs/$NODE/refresh"
run --force >/dev/null
check "pause stops the run" "RUN_HEALTH_CHECKS" "$(trace_tail)"
if [[ -f "$work/logs/$NODE/refresh" ]]; then
    printf 'ok       %-46s\n' "pause holds the refresh sentinel"
else
    printf 'FAILED   %-46s the pause consumed it\n' "pause holds the refresh sentinel"
    fails=$((fails + 1))
fi
rm -f "$work/logs/$NODE/refresh"

## 8. The one that silently corrupts the fleet: a baseline pointing at the log
## directory this run is about to rewrite.
## See docs/explanation/health-cadence.md#the-golden-baseline.
settings 'HEALTH_INTERVAL_HOURS=4'
ln -sfn "../logs/$NODE" "$work/valid-config/default"
before=$(cat "$work/logs/$NODE/alpha")
run --force >/dev/null
check "self-baseline refuses to run" "resolves to this node's own log directory" "$(trace_tail)"
check "and the baseline is untouched" "$before" "$(cat "$work/logs/$NODE/alpha")"

## A missing valid-config/ must not read as the same condition -- readlink -f
## prints nothing for both paths, and two empty strings compare equal.
rm -rf "$work/valid-config"
run --force >/dev/null
check "a missing baseline is not a self-baseline" "differs from" "$(trace_tail)"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails failed"
    exit 1
fi

#!/bin/bash
#
# Checks the time limit on each check in actions/node_health.sh: a check that
# does not return is killed, recorded as a timeout rather than as healthy, and
# the rest of the run carries on.
#
# Without it one hung tool stalled the whole cycle until systemd's 900s kill,
# with no stamp, no drain and no trace line.
# See docs/explanation/health-cadence.md#a-check-that-does-not-return.
#
# The real script is run against a stub tree, not a copy of its logic.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'pkill -KILL -f "[s]leep 28.37" 2>/dev/null; pkill -KILL -f "[s]leep 601.7" 2>/dev/null; rm -rf "$work"' EXIT

NODE=stub-node-01
export HOSTNAME="$NODE"

mkdir -p "$work"/{bin,nobin,health-checks/stub,valid-config/baseline,logs,results,etc/profile.d}
cp "$home/settings.sh" "$home/priv.sh" "$home/health-scan.sh" "$home/admin_set-baseline.sh" "$work/"
ln -sfn baseline "$work/valid-config/default"

printf '#!/bin/bash\necho idle\n'  > "$work/bin/sinfo"
printf '#!/bin/bash\nexit 0\n'     > "$work/bin/scontrol"
chmod 755 "$work/bin/sinfo" "$work/bin/scontrol"
## A PATH with everything but `timeout`, for the case where it is not installed.
find /usr/bin -maxdepth 1 ! -name timeout -exec ln -s -t "$work/nobin" {} + 2>/dev/null

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

## Every run is wrapped in its own guard (60s, or GUARD), so a regression fails
## this test instead of hanging CI. The script sources /etc/profile.d/modules.sh and calls
## `module`, neither of which exists here.
run() {
    timeout "${GUARD:-60}" env NODE_HEALTH_HOME="$work" HOSTNAME="$NODE" PATH="${RUN_PATH:-$work/bin:$PATH}" \
        bash -c 'source() { [[ "$1" == /etc/profile.d/modules.sh ]] && return 0; builtin source "$@"; }
                 module() { return 0; }
                 export -f module
                 . "$0" "$@"' "$home/actions/node_health.sh" --quiet --force 2>&1
}

## A fresh check set, baseline and log directory for each case.
reset() {
    rm -rf "$work/health-checks/stub" "$work/valid-config/baseline" "$work/logs"
    mkdir -p "$work/health-checks/stub" "$work/valid-config/baseline" "$work/logs"
}
write_check() { cat > "$work/health-checks/stub/$1.sh"; }
baseline() { printf '########INFO: Check %s\n%s\n' "$1" "$2" > "$work/valid-config/baseline/$1"; }
trace() { cat "$work/logs/$NODE/health.log" 2>/dev/null; }

fails=0
check() {
    local label="$1" want="$2" got="$3"
    if [[ "$got" == *"$want"* ]]; then
        printf 'ok       %-58s\n' "$label"
    else
        printf 'FAILED   %-58s wanted [%s] in:\n%s\n' "$label" "$want" "$got"
        fails=$((fails + 1))
    fi
}
lacks() {
    local label="$1" bad="$2" got="$3"
    if [[ "$got" != *"$bad"* ]]; then
        printf 'ok       %-58s\n' "$label"
    else
        printf 'FAILED   %-58s did not want [%s] in:\n%s\n' "$label" "$bad" "$got"
        fails=$((fails + 1))
    fi
}
under() {
    local label="$1" secs="$2" cap="$3"
    if [[ "$secs" -lt "$cap" ]]; then
        printf 'ok       %-58s %ss\n' "$label" "$secs"
    else
        printf 'FAILED   %-58s took %ss, wanted under %ss\n' "$label" "$secs" "$cap"
        fails=$((fails + 1))
    fi
}
timed() { local s=$SECONDS; "$@" > "$work/last.out" 2>&1; elapsed=$((SECONDS - s)); }

alpha_hang_omega() {
    write_check 10-alpha <<'EOF'
#!/bin/bash
# banner: ########INFO: Check alpha
echo alpha-ok
EOF
    write_check 20-hang <<'EOF'
#!/bin/bash
# banner: ########INFO: Check hang
sleep 601.7
EOF
    write_check 30-omega <<'EOF'
#!/bin/bash
# banner: ########INFO: Check omega
echo omega-ok
EOF
    baseline alpha alpha-ok; baseline hang hang-ok; baseline omega omega-ok
}

## ── 1. A hung check is killed and the run carries on ─────────────────────
reset; alpha_hang_omega
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=2'
timed run
under "a hung check no longer stalls the run" "$elapsed" 15
check "the hung check is traced as a timeout" "TIMEOUT: hang ran 2s and was killed" "$(trace)"
check "the trace says how to change the limit" "HEALTH_CHECK_TIMEOUT_SECONDS in SETTINGS, or put '# timeout: N'" "$(trace)"
check "its log holds the timeout line, under the banner" \
    "########INFO: Check hang"$'\n'"check timed out -- no result" "$(cat "$work/logs/$NODE/hang")"
check "the check before it ran" "alpha-ok" "$(cat "$work/logs/$NODE/alpha")"
check "the check after it ran" "omega-ok" "$(cat "$work/logs/$NODE/omega")"
check "only the hung check is in the finding" "differs from" "$(trace)"
lacks "the healthy checks are not blamed" "alpha omega" "$(trace | grep 'differs from')"
check "the stamp is written, as a failure" "failed" "$(cat "$work/logs/$NODE/.last-check")"
check "a timing line is traced" "timing: " "$(trace)"
check "the timing line names the slowest check" "slowest hang (" "$(trace)"
check "and where the limit is changed" "limit per check 2s -- HEALTH_CHECK_TIMEOUT_SECONDS, or '# timeout: N' in a check" "$(trace)"
check "a run with a timeout is never reported clean" "differs from" "$(trace)"

## ── 2. A child that outlives the kill must not hold the runner ───────────
## $(...) would wait for the pipe it still holds -- here, 28 seconds.
reset
write_check 10-holder <<'EOF'
#!/bin/bash
# banner: ########INFO: Check holder
bash -c 'trap "" TERM; exec sleep 28.37' &
wait
EOF
baseline holder holder-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=2'
timed run
under "a TERM-ignoring child holding stdout does not block" "$elapsed" 15
check "it is still recorded as a timeout" "TIMEOUT: holder" "$(trace)"
pkill -KILL -f "[s]leep 28.37" 2>/dev/null

## ── 3. One check can ask for more, or less, time ─────────────────────────
reset
write_check 10-short <<'EOF'
#!/bin/bash
# banner: ########INFO: Check short
# timeout: 1
sleep 5
EOF
baseline short short-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=60'
timed run
under "'# timeout: 1' beats a 60s default" "$elapsed" 10
check "and the trace names that check's limit" "TIMEOUT: short ran 1s" "$(trace)"

reset
write_check 10-slow <<'EOF'
#!/bin/bash
# banner: ########INFO: Check slow
# timeout: 8
sleep 2
echo slow-ok
EOF
baseline slow slow-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=1'
run > /dev/null
lacks "'# timeout: 8' beats a 1s default" "TIMEOUT:" "$(trace)"
check "so the slow check finishes" "slow-ok" "$(cat "$work/logs/$NODE/slow")"
check "and the run is clean" "every check matches the baseline" "$(trace)"

## ── 4. A bad value is named and never means "no limit" ───────────────────
reset
write_check 10-quick <<'EOF'
#!/bin/bash
# banner: ########INFO: Check quick
echo quick-ok
EOF
baseline quick quick-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=soon'
run > /dev/null
check "an unreadable setting is named" "HEALTH_CHECK_TIMEOUT_SECONDS=soon" "$(trace)"
check "and falls back to 90" "is not whole seconds -- using 90" "$(trace)"
check "so the cap is still on" "limit per check 90s" "$(trace)"
check "the check still ran" "quick-ok" "$(cat "$work/logs/$NODE/quick")"

reset
write_check 10-typo <<'EOF'
#!/bin/bash
# banner: ########INFO: Check typo
# timeout: soon
echo typo-ok
EOF
baseline typo typo-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=60'
run > /dev/null
check "a bad '# timeout:' is named with its check" "WARNING: typo has '# timeout: soon', not whole seconds -- using 60s" "$(trace)"

reset
write_check 10-octal <<'EOF'
#!/bin/bash
# banner: ########INFO: Check octal
# timeout: 08
echo octal-ok
EOF
baseline octal octal-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=60'
out=$(run)
lacks "'# timeout: 08' is not read as octal" "too great for base" "$out$(trace)"
check "and the check runs" "octal-ok" "$(cat "$work/logs/$NODE/octal")"

## ── 5. 0 removes the cap ─────────────────────────────────────────────────
reset
write_check 10-long <<'EOF'
#!/bin/bash
# banner: ########INFO: Check long
sleep 3
echo long-ok
EOF
write_check 20-inner <<'EOF'
#!/bin/bash
# banner: ########INFO: Check inner
timeout 1 sleep 3
EOF
baseline long long-ok; baseline inner ""
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=0'
run > /dev/null
lacks "with 0 nothing is killed" "TIMEOUT:" "$(trace)"
check "so a slow check completes" "long-ok" "$(cat "$work/logs/$NODE/long")"
check "and the timing line says there is no cap" "limit per check none" "$(trace)"
## `timeout` exits 124 for a check's own inner timeout too; that is not this one.
check "a check's own inner timeout is not taken for the runner's" "every check matches the baseline" "$(trace)"

## ── 6. The same inner 124 under a real cap ───────────────────────────────
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=30'
run > /dev/null
lacks "an inner timeout under a 30s cap is not a timeout" "TIMEOUT:" "$(trace)"

## ── 7. An informational check that hangs is traced, never drains ─────────
reset
write_check 10-alpha <<'EOF'
#!/bin/bash
# banner: ########INFO: Check alpha
echo alpha-ok
EOF
write_check 20-info <<'EOF'
#!/bin/bash
# banner: ########INFO: Check info
# informational: yes
sleep 601.7
EOF
baseline alpha alpha-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=2'
run > /dev/null
check "it is still traced" "TIMEOUT: info" "$(trace)"
check "its log records the timeout" "check timed out -- no result" "$(cat "$work/logs/$NODE/info")"
check "but it contributes no reason" "every check matches the baseline" "$(trace)"

## ── 8. A timeout is never promoted to a baseline ─────────────────────────
reset; alpha_hang_omega
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=2'
run > /dev/null
mkdir -p "$work/valid-config/old"; printf 'keep\n' > "$work/valid-config/old/alpha"
ln -sfn old "$work/valid-config/default"
out=$(cd "$work" && BRINGUP_DATA="$work" bash admin_set-baseline.sh "$NODE" 2>&1); rc=$?
check "a log holding the timeout line is refused" "1" "$rc"
check "naming the check" "log for hang is a timeout, not a result" "$out"
check "and what to do" "raise HEALTH_CHECK_TIMEOUT_SECONDS" "$out"
check "the existing baseline is untouched" "old" "$(readlink "$work/valid-config/default")"
printf '########INFO: Check hang\nhang-ok\n' > "$work/logs/$NODE/hang"
out=$(cd "$work" && BRINGUP_DATA="$work" bash admin_set-baseline.sh "$NODE" 2>&1); rc=$?
check "the same node is accepted once the check returns a result" "0" "$rc"

## ── 9. No `timeout` binary, or no temp file: said, never silent ──────────
reset
write_check 10-quick <<'EOF'
#!/bin/bash
# banner: ########INFO: Check quick
echo quick-ok
EOF
baseline quick quick-ok
settings 'HEALTH_CHECK_TIMEOUT_SECONDS=2'
RUN_PATH="$work/nobin" run > /dev/null
check "a missing timeout is traced" "WARNING: timeout is not installed -- no check has a time limit" "$(trace)"
check "and the checks still run" "quick-ok" "$(cat "$work/logs/$NODE/quick")"

## ── 10. The shipped defaults agree ───────────────────────────────────────
check "settings.sh defaults to 90" ':=90}' "$(grep 'HEALTH_CHECK_TIMEOUT_SECONDS' "$home/settings.sh")"
check "SETTINGS.default ships 90" "HEALTH_CHECK_TIMEOUT_SECONDS=90" "$(cat "$home/SETTINGS.default")"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed"
    exit 1
fi

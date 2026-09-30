#!/bin/bash
#
# The sudo layer. A refused sudo does not make a health check fail -- it makes
# it produce different output, which the baseline diff reads as a hardware
# mismatch and drains the node for. So the assertions that matter here are the
# ones about refusing to run at all.
# See docs/explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
mkdir -p "$stub" "$work/tree" "$work/checks" "$work/valid" "$work/logs"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
skip() { printf '  skip %s\n' "$*"; }

## STUB_SUDO_DENY is a space-separated list of basenames sudo refuses, matching
## a sudoers file that names some commands and not others.
cat > "$stub/sudo" <<'EOF'
#!/bin/bash
[[ "$1" == "-n" ]] && shift
listing=0
[[ "$1" == "-l" ]] && { listing=1; shift; [[ "$1" == "--" ]] && shift; }
for d in $STUB_SUDO_DENY; do
    [[ "$(basename "$1")" == "$d" ]] && { echo "sudo: a password is required" >&2; exit 1; }
done
[[ "$listing" -eq 1 ]] && exit 0
printf '%s\n' "$*" >> "$STUB_DIR/sudo.calls"
exec "$@"
EOF

cat > "$stub/dmesg" <<'EOF'
#!/bin/bash
echo "kernel: privileged output"
EOF

## Enough of a Slurm and systemd surface for node_health.sh to reach the gate.
cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
echo idle
EOF
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
[[ "$1" == "list-unit-files" ]] && { echo "slurmd.service enabled"; exit 0; }
exit 0
EOF
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
exit 0
EOF
chmod 755 "$stub"/*

echo "== priv() =="

# shellcheck source=/dev/null
source "$home/priv.sh"

out=$(PATH="$stub:$PATH" STUB_DIR="$work" STUB_SUDO_DENY="" priv dmesg 2>&1)
if [[ "$EUID" -eq 0 ]]; then
    skip "root runs the command directly; there is nothing to drop from"
elif [[ -s "$work/sudo.calls" ]] && grep -q 'privileged output' <<<"$out"; then
    ok "an unprivileged caller goes through sudo and gets the output"
else
    bad "priv did not reach sudo: [$out] calls=[$(cat "$work/sudo.calls" 2>/dev/null)]"
fi

## sudoers names absolute paths, and sudo's secure_path does not carry the tree's
## PATH -- so the resolution has to happen on this side.
if [[ "$EUID" -eq 0 ]]; then
    skip "the path resolution is only reached off the root branch"
elif grep -q "$stub/dmesg" "$work/sudo.calls" 2>/dev/null; then
    ok "the command was resolved to an absolute path before sudo saw it"
else
    bad "sudo was handed a bare name: $(cat "$work/sudo.calls" 2>/dev/null)"
fi

echo "== priv_ready() =="

if [[ "$EUID" -eq 0 ]]; then
    skip "root is ready by definition"
else
    PATH="$stub:$PATH" STUB_SUDO_DENY="" priv_ready dmesg &&
        ok "a rule that exists reads as ready" ||
        bad "a rule that exists read as missing: $PRIV_MISSING"

    if PATH="$stub:$PATH" STUB_SUDO_DENY="dmesg" priv_ready dmesg; then
        bad "a missing rule read as ready"
    elif [[ "$PRIV_MISSING" == *dmesg* ]]; then
        ok "a missing rule is named in PRIV_MISSING: $PRIV_MISSING"
    else
        bad "a missing rule was not named: [$PRIV_MISSING]"
    fi

    ## Not a privilege problem, and the check already handles the absence.
    PATH="$stub:$PATH" STUB_SUDO_DENY="" priv_ready no-such-command-anywhere &&
        ok "a command that is not installed is skipped, not reported" ||
        bad "an uninstalled command was reported as a missing rule: $PRIV_MISSING"
fi

echo "== scontrol_update() =="

if [[ "$EUID" -eq 0 ]]; then
    skip "root issues it directly"
else
    rm -f "$work/sudo.calls" "$work/scontrol.calls"
    ( export PATH="$stub:$PATH" STUB_DIR="$work" STUB_SUDO_DENY="" PRIV_SCONTROL=sudo
      scontrol_update nodename=n1 state=RESUME >/dev/null 2>&1 )
    grep -q 'scontrol' "$work/sudo.calls" 2>/dev/null &&
        ok "PRIV_SCONTROL=sudo goes through sudo" ||
        bad "PRIV_SCONTROL=sudo did not: $(cat "$work/sudo.calls" 2>/dev/null)"

    rm -f "$work/sudo.calls" "$work/scontrol.calls"
    ( export PATH="$stub:$PATH" STUB_DIR="$work" STUB_SUDO_DENY="" PRIV_SCONTROL=direct
      scontrol_update nodename=n1 state=RESUME >/dev/null 2>&1 )
    if [[ -s "$work/sudo.calls" ]]; then
        bad "PRIV_SCONTROL=direct still went through sudo"
    elif grep -q 'state=RESUME' "$work/scontrol.calls" 2>/dev/null; then
        ok "PRIV_SCONTROL=direct issues it as this account"
    else
        bad "PRIV_SCONTROL=direct issued nothing"
    fi
fi

echo "== a lost rule stops the health run =="

## A tree just complete enough for node_health.sh to reach its preflight.
cp "$home/settings.sh" "$home/priv.sh" "$work/tree/"
mkdir -p "$work/tree/actions" "$work/tree/health-checks/test" "$work/tree/valid-config/default"
cp "$home/actions/node_health.sh" "$work/tree/actions/"
cat > "$work/tree/health-checks/test/10-privileged.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Privileged
sudo -n dmesg | wc -l
EOF
cat > "$work/tree/SETTINGS" <<EOF
HEALTHCHECKS=test
JOB_USER=$(id -un)
BRINGUP_HOME=$work/tree
BRINGUP_DATA=$work/tree
RUN_HEALTH_CHECKS=yes
DRAIN_AFTER_FAILED_HEALTH_CHECK=yes
HEALTH_INTERVAL_HOURS=0
EOF
printf '########INFO: Check Privileged\n1\n' > "$work/tree/valid-config/default/privileged"

run_health() {
    ( export PATH="$stub:$PATH" STUB_DIR="$work" HOSTNAME=testnode \
             NODE_HEALTH_HOME="$work/tree" STUB_SUDO_DENY="$1"
      "$work/tree/actions/node_health.sh" --force --verbose 2>&1 )
}

if [[ "$EUID" -eq 0 ]]; then
    skip "the preflight is skipped for root, which needs no rule"
else
    rm -rf "$work/tree/logs" "$work/tree/results"
    out=$(run_health "dmesg")
    if ! grep -q 'EXIT: sudo as' <<<"$out"; then
        bad "a denied rule did not stop the run: $(tail -1 <<<"$out")"
    elif [[ -f "$work/tree/logs/testnode/privileged" ]]; then
        bad "  ... it stopped, but a check had already written its log"
    elif grep -q 'state=DOWN' "$work/scontrol.calls" 2>/dev/null; then
        bad "  ... it stopped, but the node was drained on the way"
    else
        ok "a denied rule stops the run before any check, log or drain"
    fi

    ## The list is discovered from the check files, so this is also the
    ## assertion that the discovery works at all.
    grep -q 'dmesg' <<<"$out" &&
        ok "the refused command is named in the EXIT line" ||
        bad "the EXIT line does not name what was refused: $(grep 'EXIT:' <<<"$out")"

    rm -rf "$work/tree/logs" "$work/tree/results"
    out=$(run_health "")
    if grep -q 'EXIT: sudo as' <<<"$out"; then
        bad "the run was stopped with every rule in place"
    elif [[ -f "$work/tree/logs/testnode/privileged" ]]; then
        ok "with the rule in place the checks run and write their logs"
    else
        bad "the checks did not run: $(tail -2 <<<"$out")"
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

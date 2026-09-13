#!/bin/bash
#
# Checks the check-running loop in actions/node_health.sh against a synthetic
# check set and baseline. A mistake in that loop is invisible from outside:
# see docs/reference/health-checks.md#informational-checks.
#
# The loop is extracted from the live script, not copied -- a copy would pass
# forever while the real one drifted.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work"/{set,valid,log}

## matches the baseline -- must not appear in the reason
cat > "$work/set/10-alpha.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Alpha
echo alpha-value
EOF

## differs from the baseline -- must appear, by name, with no output
cat > "$work/set/20-beta.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Beta
echo beta-drifted
EOF

## differs from the baseline but is informational -- must NOT appear
cat > "$work/set/30-gamma.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Gamma
# informational: yes
echo gamma-drifted
EOF

## differs and carries its own output into the reason
cat > "$work/set/40-dmesg-xid.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Xid
# reason-detail: yes
echo 'GPU:74'
EOF

## exits non-zero partway through: must not stop the checks after it
cat > "$work/set/50-explodes.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Explodes
echo before
exit 3
EOF

## last in numeric order -- proves the run reached the end
cat > "$work/set/60-omega.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check Omega
echo omega-drifted
EOF

printf '########INFO: Check Alpha\nalpha-value\n'     > "$work/valid/alpha"
printf '########INFO: Check Beta\nbeta-baseline\n'    > "$work/valid/beta"
printf '########INFO: Check Gamma\ngamma-baseline\n'  > "$work/valid/gamma"
printf '########INFO: Check Xid\n\n'                  > "$work/valid/dmesg-xid"
printf '########INFO: Check Explodes\nbefore\n'       > "$work/valid/explodes"
printf '########INFO: Check Omega\nomega-baseline\n'  > "$work/valid/omega"

sed -n '/^append_reason()/,/^done$/p' "$home/actions/node_health.sh" > "$work/loop.sh"
if [[ ! -s "$work/loop.sh" ]] || ! grep -q 'HEALTHCHECKS_DIR' "$work/loop.sh"; then
    echo "FAILED to extract the check loop from actions/node_health.sh" >&2
    echo "  the region from 'append_reason()' to the first 'done' no longer holds it" >&2
    exit 1
fi

reason=$(
    HEALTHCHECKS_DIR="$work/set" \
    node_health="$work/log" \
    stderrlog="$work/stderr.log" \
    valid_health="$work/valid" \
    bash -c 'reason=""; source "'"$work"'/loop.sh" 2>/dev/null
             printf "%s" "$(echo "$reason" | tr "\n" " " | sed "s/  */ /g")"'
)

fails=0
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok       %-42s %s\n' "$label" "$actual"
    else
        printf 'FAILED   %-42s got [%s], want [%s]\n' "$label" "$actual" "$expected"
        fails=$((fails + 1))
    fi
}

check "reason" " beta dmesg-xid GPU:74 omega " "$reason"

## Every check writes its log whether it drains or not, informational included
for c in alpha beta gamma dmesg-xid explodes omega; do
    if [[ -f "$work/log/$c" ]]; then
        printf 'ok       %-42s %s\n' "log written: $c" "$(head -1 "$work/log/$c")"
    else
        printf 'FAILED   %-42s no log file\n' "log written: $c"
        fails=$((fails + 1))
    fi
done

## The banner is reproduced verbatim. See docs/reference/health-checks.md#the-check-file-format.
check "banner verbatim" "########INFO: Check Alpha" "$(head -1 "$work/log/alpha")"

echo
if [[ "$fails" -eq 0 ]]; then
    echo "all checks passed"
else
    echo "$fails failed"
    exit 1
fi

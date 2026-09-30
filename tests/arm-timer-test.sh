#!/bin/bash
#
# agent/install-agent.sh: the gate that says whether the timer is scheduled. It
# runs on every node of every re-arm, so a signature that also matches a healthy
# host costs one FAILED line and one non-zero exit per node, fleet-wide.
# See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
tree="$work/tree"
mkdir -p "$stub" "$tree/agent/units" "$work/home"

## A real session has a socket here; this suite is about the timer gate, not
## the lingering one, so a working bus is simulated by default. A socket
## node, not a plain file: the install script's check is -S, matching what
## systemctl --user itself looks for.
python3 -c "import socket; socket.socket(socket.AF_UNIX).bind('$work/bus')"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## Answers `show -p <property>` out of STUB_SHOW, one `Property=value` per line,
## and anything else the install asks for the way a working manager would.
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == "-p" ]] || continue
    j=$((i + 1)); want="${!j}"
    while read -r line; do
        [[ "$line" == "$want="* ]] && { printf '%s\n' "${line#*=}"; exit 0; }
    done <<< "$STUB_SHOW"
    exit 0
done
[[ "$1 $2" == "--user is-active" ]] && exit "${STUB_ACTIVE:-0}"
exit 0
EOF
cat > "$stub/loginctl" <<'EOF'
#!/bin/bash
[[ "$*" == *Linger* ]] && echo yes
exit 0
EOF
cat > "$stub/sudo" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod 755 "$stub"/*

cp "$home/settings.sh" "$home/priv.sh" "$tree/"
cp "$home/agent/install-agent.sh" "$tree/agent/"
cp "$home/agent/units/bringup-agent."* "$tree/agent/units/"
for s in cycle.sh node-agent.sh supervisor.sh; do
    printf '#!/bin/bash\n' > "$tree/agent/$s"
    chmod 755 "$tree/agent/$s"
done
cat > "$tree/SETTINGS" <<EOF
JOB_USER=$(id -un)
BRINGUP_HOME=$tree
AGENT_INTERVAL_MINUTES=2
EXCLUDE_NODES="testhost"
PRIV_SCONTROL=direct
EOF

## --node, so the head-node branches play no part; the timer gate is the same
## either way. stderr and stdout together: FAILED goes to one and ok: the other.
run_arm() {
    ( export PATH="$stub:$PATH" HOME="$work/home" HOSTNAME=testhost \
             AGENT_HOME="$tree" XDG_RUNTIME_DIR="$work" STUB_SHOW="$1"
      "$tree/agent/install-agent.sh" --node 2>&1 )
}
timer_line() { grep -E 'timer is scheduled|timer is active|next elapse never' <<< "$1" | tail -1; }

echo "== a calendar timer that has not computed its next elapse is not a fault =="

## What a healthy node answers inside the second after `systemctl restart`: a
## calendar timer's monotonic elapse is `infinity` by construction, and the
## realtime one is 0 until the manager has worked it out. This pair was read as
## the known-bad signature and failed 2000 nodes that were arming perfectly well.
out=$(run_arm 'NextElapseUSecRealtime=0
NextElapseUSecMonotonic=infinity
TimersCalendar={ OnCalendar=*:0/2 ; next_elapse=n/a }
TimersMonotonic=')
line=$(timer_line "$out")
case "$line" in
    *"next elapse never"*) bad "a calendar timer mid-restart was called a fault: $line" ;;
    *"is active"*)         ok  "reported as active and not yet computed: $line" ;;
    *)                     bad "no verdict on the timer at all: ${line:-<nothing>}" ;;
esac
grep -q '^FAILED' <<< "$out" &&
    bad "it still failed the install: $(grep '^FAILED' <<< "$out")" ||
    ok "nothing failed, so the node does not come back as an error over the fan-out"

echo "== the stale monotonic unit is still caught =="

## The real fault: a manager holding a unit built on OnUnitActiveSec=. It fires
## once per manager start and never again, and it says so by having a monotonic
## timer and no calendar one -- which no amount of waiting changes.
out=$(run_arm 'NextElapseUSecRealtime=0
NextElapseUSecMonotonic=infinity
TimersCalendar=
TimersMonotonic={ OnUnitActiveSec=2min ; next_elapse=n/a }')
line=$(timer_line "$out")
case "$line" in
    *"next elapse never"*) ok  "named as the monotonic unit it is: $line" ;;
    *)                     bad "a timer that will never fire again passed: ${line:-<nothing>}" ;;
esac

echo "== a scheduled timer passes on the elapse alone =="

out=$(run_arm 'NextElapseUSecRealtime=1799999999000000
NextElapseUSecMonotonic=infinity
TimersCalendar={ OnCalendar=*:0/2 ; next_elapse=n/a }
TimersMonotonic=')
line=$(timer_line "$out")
case "$line" in
    *"is scheduled"*) ok  "reported scheduled: $line" ;;
    *)                bad "a timer with a next elapse was not called scheduled: ${line:-<nothing>}" ;;
esac

echo "== systemd saying nothing is not systemd saying no =="

## An unreadable answer is the third outcome, and it prints what came back
## rather than a verdict. See docs/how-to/arm-a-node.md#armed-but-never-heartbeats.
out=$(run_arm '')
line=$(timer_line "$out")
case "$line" in
    *"next elapse never"*) bad "an empty answer was read as broken: $line" ;;
    *"is active"*)         ok  "reported as active with what show returned: $line" ;;
    *)                     bad "no verdict on the timer at all: ${line:-<nothing>}" ;;
esac

echo "== lingering enabled does not mean this session can use it =="

## loginctl reporting the flag as set is not the same fact as a bus this
## session can reach -- a directory with no bus socket in it is what a
## session that predates lingering taking effect looks like.
mkdir -p "$work/no-bus"
out=$(
    export PATH="$stub:$PATH" HOME="$work/home" HOSTNAME=testhost \
           AGENT_HOME="$tree" XDG_RUNTIME_DIR="$work/no-bus" STUB_SHOW=''
    "$tree/agent/install-agent.sh" --node 2>&1
)
if grep -q 'no user bus reachable in this session' <<< "$out"; then
    ok "named the real cause, not a unit-install failure"
else
    bad "the missing bus was not diagnosed: $out"
fi
if grep -q 'daemon-reload\|enable --now' <<< "$out"; then
    bad "carried on into systemctl --user anyway: $out"
else
    ok "stopped before the systemctl --user calls that cannot work here"
fi

echo "== SETTINGS_HOME resolving nowhere is caught, not silently defaulted =="

## A pointer that names a file nobody ever created. settings.sh falls through
## to coded defaults rather than failing -- JOB_USER exported so the run gets
## past the earlier account-match gate on that same coded default, and
## reaches the check this case is actually about.
## See docs/how-to/arm-a-node.md#armed-with-no-settings.
echo "$work/nowhere/SETTINGS" > "$tree/SETTINGS_HOME"
me=$(id -un)
out=$(
    export PATH="$stub:$PATH" HOME="$work/home" HOSTNAME=testhost \
           AGENT_HOME="$tree" XDG_RUNTIME_DIR="$work" JOB_USER="$me" \
           STUB_SHOW='NextElapseUSecRealtime=1799999999000000
NextElapseUSecMonotonic=infinity
TimersCalendar={ OnCalendar=*:0/2 ; next_elapse=n/a }
TimersMonotonic='
    "$tree/agent/install-agent.sh" --node 2>&1
)
if grep -q 'FAILED: SETTINGS_HOME resolves nowhere readable' <<< "$out"; then
    ok "named the unreadable pointer rather than cycling on coded defaults silently"
else
    bad "a pointer to nothing was not caught: $out"
fi
rm -f "$tree/SETTINGS_HOME"

echo "== a resolving SETTINGS_HOME is not reported as a fault =="

echo "$tree/SETTINGS" > "$tree/SETTINGS_HOME"
out=$(run_arm 'NextElapseUSecRealtime=1799999999000000
NextElapseUSecMonotonic=infinity
TimersCalendar={ OnCalendar=*:0/2 ; next_elapse=n/a }
TimersMonotonic=')
if grep -q "ok: reading settings from $tree/SETTINGS" <<< "$out"; then
    ok "named the resolved file"
elif grep -q 'FAILED: SETTINGS_HOME resolves nowhere' <<< "$out"; then
    bad "a pointer that resolves was reported as broken: $out"
else
    bad "no verdict on SETTINGS_FILE at all: $out"
fi
rm -f "$tree/SETTINGS_HOME"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

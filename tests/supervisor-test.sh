#!/bin/bash
#
# agent/supervisor.sh: which nodes get armed, and which do not. Both errors are
# expensive and neither is visible from the cluster -- arming too widely is an
# ssh storm every two minutes, arming nothing is a fleet that has quietly
# stopped testing while every node still reads `idle`.
# See docs/explanation/the-agent-and-the-watchdog.md#which-states-are-armed.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
tree="$work/tree"
mkdir -p "$stub" "$tree/agent"

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## STUB_SINFO is verbatim `sinfo -N -h -o '%N %T'` output. Empty is the case a
## saturated controller produces and must never read as an empty cluster.
cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
[[ -n "$STUB_SINFO" ]] && printf '%s\n' "$STUB_SINFO"
exit 0
EOF
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
[[ -n "$STUB_SQUEUE" ]] && printf '%s\n' "$STUB_SQUEUE"
exit 0
EOF
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
exit 0
EOF
## Records the whole invocation, then answers as install-agent.sh would for each
## node in -w. STUB_ARM_FAIL names one node that refuses. Both tools are on PATH
## so the suite exercises whichever fanout() picks -- clush, as it ships.
## See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.
cat > "$stub/pdsh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/fanout.calls"
want=""
for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == "-w" ]] && { j=$((i + 1)); want="${!j}"; }
done
for n in ${want//,/ }; do
    if [[ "$n" == "$STUB_ARM_FAIL" ]]; then
        printf '%s: FAILED: could not enable lingering for cmods\n' "$n"
    else
        printf '%s: ok: bringup-agent.timer enabled and started on %s\n' "$n" "$n"
    fi
done
exit 0
EOF
sed 's|/pdsh.calls|/fanout.calls|' "$stub/pdsh" > "$stub/clush"
chmod 755 "$stub"/*

cp "$home/settings.sh" "$home/priv.sh" "$home/fanout.sh" "$home/report-format.sh" "$tree/"
cp "$home/agent/supervisor.sh" "$tree/agent/"
cat > "$tree/SETTINGS" <<EOF
JOB_USER=$(id -un)
BRINGUP_HOME=$tree
HEARTBEAT_STALE_MINUTES=10
ARM_RETRY_MINUTES=10
ARM_MAX_ATTEMPTS=3
ARM_WINDOW_HOURS=24
MAX_JOB_HOURS=7
DRAIN_AFTER_FAILED_BENCHMARK=yes
PAUSE_ARMING=no
PRIV_SCONTROL=direct
EOF

results="$tree/results"

## A heartbeat $1 seconds old for node $2. No argument at all means the node has
## never written one.
beat() {
    mkdir -p "$results/$2"
    touch -d "@$(( $(date +%s) - $1 ))" "$results/$2/.heartbeat"
}

run_sup() {
    rm -f "$work/fanout.calls" "$work/scontrol.calls"
    ( export PATH="$stub:$PATH" HOSTNAME=headnode AGENT_HOME="$tree" STUB_DIR="$work" \
             STUB_SINFO="$1" STUB_SQUEUE="${STUB_SQUEUE:-}" STUB_ARM_FAIL="${STUB_ARM_FAIL:-}"
      "$tree/agent/supervisor.sh" "${2:---quiet}" >/dev/null 2>&1 )
}

armed()      { grep -q "\b$1\b" "$work/fanout.calls" 2>/dev/null; }
last_line()  { tail -1 "$results/supervisor.log" 2>/dev/null; }

echo "== which states are armed =="

rm -rf "$results"
for n in n-idle n-drained n-alloc n-mixed n-down n-draining n-maint n-noresp; do
    beat 3600 "$n"
done
run_sup 'n-idle idle
n-drained drained
n-alloc allocated
n-mixed mixed
n-down down
n-draining draining
n-maint maint
n-noresp idle*'

armed n-idle    && ok "idle is armed"          || bad "idle was not armed"
armed n-drained && ok "drained is armed"       || bad "drained was not armed -- a drained node stops being health-checked"
for n in n-alloc n-mixed n-down n-draining n-maint n-noresp; do
    armed "$n" && bad "$n was armed" || ok "$n is left alone"
done

echo "== one fan-out, not a loop of sshes =="

[[ "$(wc -l < "$work/fanout.calls")" -eq 1 ]] &&
    ok "two stale nodes went out in one call" ||
    bad "$(wc -l < "$work/fanout.calls") calls for one cycle"
grep -q -- '-w ' "$work/fanout.calls" &&
    ok "as a nodeset on -w, not a node at a time: $(cat "$work/fanout.calls")" ||
    bad "the fan-out took no -w: $(cat "$work/fanout.calls")"

## clush ships preferred, and a site that installed it must not be silently
## getting pdsh -- so the trace names which one went out. The resolution itself
## is tests/fanout-test.sh.
if grep -q 'over clush' "$results/supervisor.log"; then
    ok "and the trace names the tool it used: clush"
else
    bad "the trace does not name clush as the tool that armed them: $(grep ARM "$results/supervisor.log" | tail -1)"
fi

echo "== fresh heartbeats are left alone =="

rm -rf "$results"
beat 60 n-fresh
beat 3600 n-stale
run_sup 'n-fresh idle
n-stale idle'
armed n-fresh && bad "a node cycling a minute ago was armed" || ok "a fresh heartbeat is left alone"
armed n-stale && ok "a stale one is armed"                   || bad "a stale heartbeat was not armed"

## A node dir with no heartbeat at all has never been armed, and is the case a
## fresh deployment is entirely made of.
rm -rf "$results"; mkdir -p "$results/n-never"
run_sup 'n-never idle'
armed n-never && ok "a node that has never written one is armed" ||
    bad "a node with no heartbeat was skipped: $(last_line)"

echo "== no answer is not an answer =="

rm -rf "$results"
beat 3600 n-stale
run_sup ''
if [[ -s "$work/fanout.calls" ]]; then
    bad "an empty sinfo armed something -- a busy controller looks exactly like this"
else
    ok "empty sinfo output arms nothing: $(last_line)"
fi
grep -q "returned nothing" <<<"$(last_line)" &&
    ok "and says so rather than reporting an empty fleet" ||
    bad "the empty answer was not explained: $(last_line)"

echo "== the arm rate limit =="

rm -rf "$results"
beat 3600 n-recent
printf '%s\tok\n' "$(( $(date +%s) - 120 ))" > "$results/n-recent/arm.log"
run_sup 'n-recent idle'
armed n-recent && bad "a node armed two minutes ago was armed again" ||
    ok "a node inside ARM_RETRY_MINUTES waits: $(last_line)"

rm -rf "$results"
beat 3600 n-hopeless
for i in 3 2 1; do
    printf '%s\tno output from clush\n' "$(( $(date +%s) - i * 3600 ))" >> "$results/n-hopeless/arm.log"
done
run_sup 'n-hopeless idle'
if armed n-hopeless; then
    bad "a node armed 3 times in the window was armed a fourth"
elif grep -q 'left for an operator' <<<"$(last_line)"; then
    ok "past ARM_MAX_ATTEMPTS it is named and left: $(last_line)"
else
    bad "it was skipped, but silently: $(last_line)"
fi

## Old attempts fall out of the window rather than counting for ever.
rm -rf "$results"
beat 3600 n-oldfails
for i in 100 99 98; do
    printf '%s\tno output from clush\n' "$(( $(date +%s) - i * 3600 ))" >> "$results/n-oldfails/arm.log"
done
run_sup 'n-oldfails idle'
armed n-oldfails && ok "attempts older than ARM_WINDOW_HOURS do not count" ||
    bad "a node was held off by attempts from four days ago: $(last_line)"

echo "== what came back is recorded per node =="

rm -rf "$results"
beat 3600 n-ok; beat 3600 n-bad
STUB_ARM_FAIL=n-bad run_sup 'n-ok idle
n-bad idle'
grep -q 'enabled and started' "$results/n-ok/arm.log" 2>/dev/null &&
    ok "a successful arm is recorded against the node" ||
    bad "nothing was recorded for n-ok: $(cat "$results/n-ok/arm.log" 2>/dev/null)"
grep -q 'lingering' "$results/n-bad/arm.log" 2>/dev/null &&
    ok "a refusal is recorded with what the node said" ||
    bad "the refusal was not recorded: $(cat "$results/n-bad/arm.log" 2>/dev/null)"
grep -q 'ARM FAILED n-bad' "$results/supervisor.log" &&
    ok "and named in the trace" ||
    bad "the failure did not reach the trace"
unset STUB_ARM_FAIL

echo "== PAUSE_ARMING =="

rm -rf "$results"
beat 3600 n-stale
sed -i 's/^PAUSE_ARMING=no/PAUSE_ARMING=yes/' "$tree/SETTINGS"
run_sup 'n-stale idle'
[[ -s "$work/fanout.calls" ]] && bad "PAUSE_ARMING=yes still armed a node" ||
    ok "PAUSE_ARMING=yes arms nothing: $(last_line)"
sed -i 's/^PAUSE_ARMING=yes/PAUSE_ARMING=no/' "$tree/SETTINGS"

echo "== the job that outran MAX_JOB_HOURS =="

## The node's own cycle stops at the busy gate, so this drain is the watchdog's.
## See docs/explanation/sequencing.md#the-busy-gate.
rm -rf "$results"
beat 60 n-long
printf '4242\tmnubergemm\t1\t12\t%s\n' "$(( $(date +%s) - 8 * 3600 ))" > "$results/n-long/.in-flight"
STUB_SQUEUE='4242 RUNNING' run_sup 'n-long allocated'
grep -q 'state=DRAIN' "$work/scontrol.calls" 2>/dev/null &&
    ok "a job running 8h past a 7h limit drains the node" ||
    bad "no drain was issued: $(last_line)"
grep -q 'job timeout after 8h' "$work/scontrol.calls" 2>/dev/null &&
    ok "the reason names the overrun and the job" ||
    bad "the drain reason is wrong: $(cat "$work/scontrol.calls" 2>/dev/null)"

## A job queued behind a dead node reads 0:00 for as long as it waits, and
## "timeout" would bury the real reason the node is unusable.
rm -rf "$results"
beat 60 n-pend
printf '4243\tmnubergemm\t1\t12\t%s\n' "$(( $(date +%s) - 8 * 3600 ))" > "$results/n-pend/.in-flight"
STUB_SQUEUE='4243 PENDING' run_sup 'n-pend idle'
grep -q 'state=DRAIN' "$work/scontrol.calls" 2>/dev/null &&
    bad "a job that never started was drained for a timeout" ||
    ok "only a RUNNING job is measured against the limit"

## Inside the limit, nothing happens.
rm -rf "$results"
beat 60 n-short
printf '4244\tallreduce\t1\t1\t%s\n' "$(( $(date +%s) - 600 ))" > "$results/n-short/.in-flight"
STUB_SQUEUE='4244 RUNNING' run_sup 'n-short allocated'
grep -q 'state=DRAIN' "$work/scontrol.calls" 2>/dev/null &&
    bad "a job ten minutes old was drained" ||
    ok "a job inside MAX_JOB_HOURS is left alone"

## The same switch that governs every other drain this framework issues.
rm -rf "$results"
beat 60 n-long
printf '4242\tmnubergemm\t1\t12\t%s\n' "$(( $(date +%s) - 8 * 3600 ))" > "$results/n-long/.in-flight"
sed -i 's/^DRAIN_AFTER_FAILED_BENCHMARK=yes/DRAIN_AFTER_FAILED_BENCHMARK=no/' "$tree/SETTINGS"
STUB_SQUEUE='4242 RUNNING' run_sup 'n-long allocated'
if grep -q 'state=DRAIN' "$work/scontrol.calls" 2>/dev/null; then
    bad "DRAIN_AFTER_FAILED_BENCHMARK=no still drained the node"
elif grep -q 'drain suppressed' "$results/supervisor.log"; then
    ok "with drains off the finding is still written down: $(grep -h 'drain suppressed' "$results/supervisor.log" | tail -1)"
else
    bad "the suppressed drain was not traced: $(last_line)"
fi
sed -i 's/^DRAIN_AFTER_FAILED_BENCHMARK=no/DRAIN_AFTER_FAILED_BENCHMARK=yes/' "$tree/SETTINGS"

echo "== --explain touches nothing =="

rm -rf "$results"
beat 3600 n-stale
printf '4242\tmnubergemm\t1\t12\t%s\n' "$(( $(date +%s) - 8 * 3600 ))" > "$results/n-stale/.in-flight"
STUB_SQUEUE='4242 RUNNING' run_sup 'n-stale idle' --explain
[[ -s "$work/fanout.calls" ]] && bad "--explain armed a node" || ok "--explain armed nothing"
## Not "scontrol was never called": compress() reads `scontrol show hostlistsorted`
## to print the node list, and a read is not a change.
grep -q 'state=DRAIN' "$work/scontrol.calls" 2>/dev/null &&
    bad "--explain drained a node" || ok "--explain drained nothing"
[[ -f "$results/n-stale/arm.log" ]] && bad "--explain recorded an attempt" ||
    ok "--explain recorded no attempt"
grep -q 'WOULD ARM' "$results/supervisor.log" &&
    ok "and said what it would have done" ||
    bad "--explain did not name what it would arm: $(last_line)"

echo "== the filters =="

rm -rf "$results"
beat 3600 n-in; beat 3600 n-out
cat >> "$tree/SETTINGS" <<'EOF'
EXCLUDE_NODES="n-out"
EOF
run_sup 'n-in idle
n-out idle'
armed n-out && bad "an EXCLUDE_NODES host was armed" || ok "EXCLUDE_NODES is honoured"
armed n-in  && ok "and the rest of the fleet is not affected" || bad "n-in was not armed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

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

## STUB_SINFO stays `<node> <state>` per line, which is what every case below is
## written in; the stub renders it into the two formats the snapshot library asks
## for. Empty is the case a saturated controller produces and must never read as
## an empty cluster. See docs/explanation/the-fleet-snapshot.md#the-two-queries.
cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
[[ -n "$STUB_SINFO" ]] || exit 0
## The hardware call: node, gres, cpus.
for a in "$@"; do
    [[ "$a" == '%N|%G|%c' ]] &&
        { awk '{ print $1 "|gpu:gb200:4|72" }' <<< "$STUB_SINFO"; exit 0; }
done
## Real sinfo can split a free-text reason across physical lines.  Keep this
## separate from the compact case input above so the hardware query still has
## a normal node list to render.
[[ -n "$STUB_SINFO_RAW" ]] && { printf '%s\n' "$STUB_SINFO_RAW"; exit 0; }
## The state call: node, state, who set the drain, when, and the free-text reason
## last. The cases care only about the first two.
awk '{ print $1 "|" $2 "|none||" $3 }' <<< "$STUB_SINFO"
exit 0
EOF

## STUB_SQUEUE stays `<id> <state>` per line and is rendered into the twelve
## fields snapshot_query reads. The name carries a node so the fleet count and
## the per-node view have something to key on.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
[[ -n "$STUB_SQUEUE" ]] || exit 0
awk -v n="${STUB_JOB_NODE:-n-long}" \
    '{ print $1 "|bringup-" n "|" ENVIRON["USER"] "|" $2 "|4294901759|2026-01-01T00:00:00|N/A|" \
             ($2 == "RUNNING" ? n : "") "|" n "|" n "|1|None" }' <<< "$STUB_SQUEUE"
exit 0
EOF

cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
## snapshot_expand asks for hostnames; every other call here is an update.
[[ "$1" == "show" && "$2" == "hostnames" ]] && printf '%s\n' ${3//,/ }
exit 0
EOF
cat > "$stub/scancel" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scancel.calls"
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

cp "$home/settings.sh" "$home/priv.sh" "$home/fanout.sh" "$home/report-format.sh" \
   "$home/slurm-snapshot.sh" "$home/get-out-of-the-way.sh" "$tree/"
cp "$home/agent/supervisor.sh" "$tree/agent/"
cat > "$tree/SETTINGS" <<EOF
JOB_USER=$(id -un)
BRINGUP_HOME=$tree
BRINGUP_DATA=$tree
HEARTBEAT_STALE_MINUTES=10
ARM_RETRY_MINUTES=10
ARM_MAX_ATTEMPTS=3
ARM_WINDOW_HOURS=24
MAX_JOB_HOURS=7
DRAIN_AFTER_FAILED_BENCHMARK=yes
RUN_ARMING=yes
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
    rm -f "$work/fanout.calls" "$work/scontrol.calls" "$work/scancel.calls"
    ( export PATH="$stub:$PATH" HOSTNAME=headnode AGENT_HOME="$tree" STUB_DIR="$work" \
             STUB_SINFO="$1" STUB_SINFO_RAW="${STUB_SINFO_RAW:-}" \
             STUB_SQUEUE="${STUB_SQUEUE:-}" STUB_ARM_FAIL="${STUB_ARM_FAIL:-}" \
             STUB_RAW_QUEUE="${STUB_RAW_QUEUE:-}" STUB_JOB_NODE="${STUB_JOB_NODE:-n-long}"
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

echo "== multiline Slurm reasons stay reasons =="

rm -rf "$results"
beat 3600 n-reset
STUB_SINFO_RAW=$'n-reset|drained|root|2026-08-12T13:53:00|Reset; rebooting to clear\n  Reset; rebooting to clear : Not responding'
run_sup 'n-reset drained'
unset STUB_SINFO_RAW
[[ -f "$results/n-reset/.slurm-view" ]] &&
    ok "the real node received its view" ||
    bad "the real node lost its view to a multiline reason"
grep -q $'^reason\tReset; rebooting to clear Reset; rebooting to clear : Not responding$' \
    "$results/n-reset/.slurm-view" &&
    ok "the continuation was kept with the drain reason" ||
    bad "the drain reason was not reconstructed: $(cat "$results/n-reset/.slurm-view" 2>/dev/null)"
if [[ -e "$results/  Reset; rebooting to clear" ||
      -e "$results/  Reset; rebooting to clear : Not responding" ]]; then
    bad "a reason continuation became a results directory"
else
    ok "a reason continuation cannot become a results directory"
fi

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
elif grep -q 'left for an operator' "$results/supervisor.log"; then
    ok "past ARM_MAX_ATTEMPTS it is named and left: $(grep -h 'left for an operator' "$results/supervisor.log" | tail -1)"
else
    bad "it was skipped, but silently: $(last_line)"
fi

grep -q "cycle.sh --verbose" "$results/supervisor.log" &&
    ok "  ... and the line says what to run on them" ||
    bad "  ... but not what to do about it: $(last_line)"

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

echo "== arming is bounded =="

## Every arm is an ssh from one host, and a fleet that stops cycling for any
## reason makes every node stale in the same instant.
## See docs/explanation/the-agent-and-the-watchdog.md#arming-is-bounded.
rm -rf "$results"
big=""
for i in $(seq 1 12); do beat 3600 "n$i"; big+="n$i idle
"; done
printf 'ARM_BATCH=5\n' >> "$tree/SETTINGS"
run_sup "${big%$'\n'}"
## The -w argument, not the whole line: the command that follows it has commas
## and spaces of its own.
armed_count=$(sed -n 's/.*-w \([^ ]*\).*/\1/p' "$work/fanout.calls" | tr ',' '\n' | grep -c .)
[[ "$armed_count" -eq 5 ]] &&
    ok "12 stale nodes, ARM_BATCH=5, five went out" ||
    bad "the cap did not hold: $armed_count went out"
grep -q 'held back by ARM_BATCH=5' "$results/supervisor.log" &&
    ok "and the rest are named as deferred, not dropped" ||
    bad "the deferred nodes were not accounted for: $(last_line)"

## Deferred is not lost: the next cycle takes the next batch.
rm -f "$work/fanout.calls"
touch -d "@$(( $(date +%s) - 3600 ))" "$results/.supervisor-heartbeat" 2>/dev/null
run_sup "${big%$'\n'}"
[[ -s "$work/fanout.calls" ]] &&
    ok "the next cycle picks up where it left off" ||
    bad "nothing was armed on the following cycle"
sed -i '/^ARM_BATCH=5/d' "$tree/SETTINGS"

echo "== only one watchdog =="

## Every host runs the same unit and decides its own role, so two reading as
## head would both arm the fleet.
## See docs/explanation/the-agent-and-the-watchdog.md#only-one-watchdog.
rm -rf "$results"; beat 3600 n-stale
run_sup 'n-stale idle'
[[ -f "$results/.supervisor-owner" ]] &&
    ok "the first watchdog to run claims the fleet" ||
    bad "no claim was written"
grep -q "^headnode" "$results/.supervisor-owner" &&
    ok "and the claim names it" ||
    bad "the claim does not name the host: $(cat "$results/.supervisor-owner" 2>/dev/null)"

## A second host, with the first one's claim still fresh.
rm -f "$work/fanout.calls"
( export PATH="$stub:$PATH" HOSTNAME=headnode2 AGENT_HOME="$tree" STUB_DIR="$work" \
         STUB_SINFO='n-stale idle'
  "$tree/agent/supervisor.sh" --quiet >/dev/null 2>&1 )
if [[ -s "$work/fanout.calls" ]]; then
    bad "a second host armed nodes while another watchdog holds the claim"
else
    ok "a second host stands by rather than arming the same fleet"
fi
grep -q 'stands by' "$results/supervisor.log" &&
    ok "and says which host is holding it" ||
    bad "the stand-down was not explained: $(last_line)"
grep -q "^headnode\b" "$results/.supervisor-owner" &&
    ok "the claim is not stolen while it is fresh" ||
    bad "the standby host took the claim: $(cat "$results/.supervisor-owner")"

## The watchdog has to survive its host dying, so a stale claim is taken over.
touch -d "@$(( $(date +%s) - 3600 ))" "$results/.supervisor-owner"
rm -f "$work/fanout.calls"
( export PATH="$stub:$PATH" HOSTNAME=headnode2 AGENT_HOME="$tree" STUB_DIR="$work" \
         STUB_SINFO='n-stale idle'
  "$tree/agent/supervisor.sh" --quiet >/dev/null 2>&1 )
grep -q "^headnode2" "$results/.supervisor-owner" &&
    ok "a claim past its lease is taken over" ||
    bad "a dead watchdog's claim was never released: $(cat "$results/.supervisor-owner")"
grep -q 'took the watchdog claim from headnode' "$results/supervisor.log" &&
    ok "and the takeover is written down" ||
    bad "the takeover was silent"

## The deterministic answer for a site with two hosts that read as head.
rm -rf "$results"; beat 3600 n-stale
printf 'SUPERVISOR_HOST=somewhere-else\n' >> "$tree/SETTINGS"
rm -f "$work/fanout.calls"
run_sup 'n-stale idle'
[[ -s "$work/fanout.calls" ]] &&
    bad "SUPERVISOR_HOST named another host and this one armed anyway" ||
    ok "SUPERVISOR_HOST pins it: a host that is not named arms nothing"
sed -i '/^SUPERVISOR_HOST=somewhere-else/d' "$tree/SETTINGS"

echo "== RUN_ARMING =="

rm -rf "$results"
beat 3600 n-stale
sed -i 's/^RUN_ARMING=yes/RUN_ARMING=no/' "$tree/SETTINGS"
run_sup 'n-stale idle'
[[ -s "$work/fanout.calls" ]] && bad "RUN_ARMING=no still armed a node" ||
    ok "RUN_ARMING=no arms nothing: $(last_line)"
sed -i 's/^RUN_ARMING=no/RUN_ARMING=yes/' "$tree/SETTINGS"

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

echo "== the node view is written for the fleet =="

## The whole point of the watchdog's queries: two of them, and every node reads
## a file. See docs/explanation/the-fleet-snapshot.md.
rm -rf "$results"
beat 60 n-a; beat 60 n-b
STUB_SQUEUE='4242 RUNNING' STUB_JOB_NODE=n-a run_sup 'n-a idle
n-b idle'
for n in n-a n-b; do
    [[ -f "$results/$n/.slurm-view" ]] &&
        ok "$n was given a view" || bad "$n got no view -- it will stop deciding"
done
grep -q '^end' "$results/n-a/.slurm-view" &&
    ok "the view is sealed, so a torn read is detectable" ||
    bad "the view has no end marker"
grep -q '^ours	4242	RUNNING' "$results/n-a/.slurm-view" &&
    ok "a job of ours reaches the node it was submitted for" ||
    bad "n-a's view does not carry its own job: $(cat "$results/n-a/.slurm-view")"
grep -q '^ours' "$results/n-b/.slurm-view" &&
    bad "n-b was given another node's job" ||
    ok "and does not reach a node it is not for"
## A view is what the controller said, not an action taken on it, so it is
## written whatever else this cycle is or is not allowed to do.
rm -rf "$results"; beat 3600 n-paused
sed -i 's/^RUN_ARMING=yes$/RUN_ARMING=no/' "$tree/SETTINGS"
run_sup 'n-paused idle'
armed n-paused && bad "RUN_ARMING=no armed a node" || ok "RUN_ARMING=no still arms nothing"
[[ -f "$results/n-paused/.slurm-view" ]] &&
    ok "but the view is still written, so the fleet keeps deciding" ||
    bad "RUN_ARMING=no stopped the views, which stops every agent"
sed -i 's/^RUN_ARMING=no$/RUN_ARMING=yes/' "$tree/SETTINGS"

echo "== the cancels that left the nodes =="

## Both of these were a squeue per node per cycle. They are one pass over the
## queue this cycle already read.
## See docs/explanation/the-fleet-snapshot.md#what-moved-to-the-head-node.
rm -rf "$results"; beat 60 n-held
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
[[ -n "$STUB_RAW_QUEUE" ]] && printf '%s\n' "$STUB_RAW_QUEUE"
exit 0
EOF
chmod 755 "$stub/squeue"

STUB_RAW_QUEUE="7001|bringup-n-held|$(id -un)|PENDING|0|2026-01-01T00:00:00|N/A||n-held|n-held|1|launch failed requeued held" \
    run_sup 'n-held idle'
grep -q '7001' "$work/scancel.calls" 2>/dev/null &&
    ok "a job held after a failed launch is cancelled from here" ||
    bad "the held job was left to wait for ever: $(cat "$work/scancel.calls" 2>/dev/null)"

## Ours by prefix is the gate. A foreign job held the same way is somebody's.
rm -rf "$results"; beat 60 n-held
STUB_RAW_QUEUE="7002|train-70b|alice|PENDING|0|2026-01-01T00:00:00|N/A||n-held|n-held|1|launch failed requeued held" \
    run_sup 'n-held idle'
[[ -f "$work/scancel.calls" ]] &&
    bad "somebody else's held job was cancelled: $(cat "$work/scancel.calls")" ||
    ok "a foreign held job is left alone"

rm -rf "$results"; beat 60 n-pj
sed -i 's/^RUN_ARMING=yes$/RUN_ARMING=yes\nRUN_JOBS=no/' "$tree/SETTINGS"
STUB_RAW_QUEUE="7003|bringup-n-pj|$(id -un)|PENDING|4294901759|2026-01-01T00:00:00|N/A||n-pj|n-pj|1|Resources
7004|burnin-n-pj|$(id -un)|RUNNING|4294901759|2026-01-01T00:00:00|N/A|n-pj|n-pj||1|None" \
    run_sup 'n-pj idle'
grep -q '7003' "$work/scancel.calls" 2>/dev/null &&
    ok "RUN_JOBS=no cancels a pending job of ours" ||
    bad "RUN_JOBS=no left a pending job queued: $(cat "$work/scancel.calls" 2>/dev/null)"
grep -q '7004' "$work/scancel.calls" 2>/dev/null &&
    bad "RUN_JOBS=no killed a running job -- it is meant to be left to finish" ||
    ok "and leaves the running one to finish"
sed -i '/^RUN_JOBS=no$/d' "$tree/SETTINGS"

## Restored for the cases below, which drive the queue through STUB_SQUEUE.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
[[ -n "$STUB_SQUEUE" ]] || exit 0
awk -v n="${STUB_JOB_NODE:-n-long}" \
    '{ print $1 "|bringup-" n "|" ENVIRON["USER"] "|" $2 "|4294901759|2026-01-01T00:00:00|N/A|" \
             ($2 == "RUNNING" ? n : "") "|" n "|" n "|1|None" }' <<< "$STUB_SQUEUE"
exit 0
EOF
chmod 755 "$stub/squeue"

echo "== widespread submission failures open one fleet circuit =="

rm -rf "$results"
for n in n-submit1 n-submit2 n-submit3; do
    beat 60 "$n"
    printf '%s\t%s\t1\tprobe\t1\t1\t1\t%s\n' "$(date +%s)" \
        "$(( $(date +%s) + 120 ))" "sbatch: error: Socket timed out on send/recv operation" \
        > "$results/$n/.submit-retry"
done
printf 'SUBMIT_CIRCUIT_FAILURES=3\n' >> "$tree/SETTINGS"
run_sup 'n-submit1 idle
n-submit2 idle
n-submit3 idle'
if [[ -f "$results/.submit-circuit" ]]; then
    ok "three matching recent failures open the fleet circuit"
else
    bad "matching submission failures did not open the circuit: $(last_line)"
fi
grep -q 'OPEN submission circuit' "$results/supervisor.log" &&
    ok "the circuit names its threshold and diagnostic" ||
    bad "the circuit opening was not traced"
IFS=$'\t' read -r _ circuit_until circuit_count circuit_diag < "$results/.submit-circuit"
[[ "$circuit_until" -gt "$(date +%s)" && "$circuit_count" -eq 3 ]] &&
    ok "the shared hold carries an expiry and matching count" ||
    bad "the shared circuit marker is malformed: $(cat "$results/.submit-circuit" 2>/dev/null)"
[[ "$circuit_diag" == *"Socket timed out"* ]] &&
    ok "the shared hold retains Slurm's diagnosis" ||
    bad "the circuit lost the diagnosis: $circuit_diag"

rm -f "$results"/*/.submit-retry
rm -f "$results/.supervisor-heartbeat"
printf '%s\t%s\t2789\t%s\n' "$(( $(date +%s) - 1200 ))" \
    "$(( $(date +%s) - 600 ))" "sbatch: error: stale failure" \
    > "$results/.submit-circuit"
run_sup 'n-submit1 idle
n-submit2 idle
n-submit3 idle'
if [[ ! -e "$results/.submit-circuit" ]]; then
    ok "an expired circuit discards its saved failure count"
else
    bad "an expired circuit reopened from its stale count: $(cat "$results/.submit-circuit" 2>/dev/null)"
fi
sed -i '/^SUBMIT_CIRCUIT_FAILURES=3$/d' "$tree/SETTINGS"

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

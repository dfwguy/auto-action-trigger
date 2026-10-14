#!/bin/bash
#
# actions/launch_job.sh: the burn-in round-robin (burnin_order), the shared
# BURNIN_HOURS stop gate, and job_run_seconds' --time_to_run/STEP_TIMELIMIT
# fallback. Also checks verdict-scan.sh's burnin_hours_cell renders the
# "<N>H/<BURNIN_HOURS>H" form report_job-status.sh and the other reports print.
#
# Issue #3: BURNIN used to run one job to its own totalRuns before the next
# was ever touched, and every report grew a column per run. This suite is the
# worked example from that decision: three jobs, fewest-passed-first, ties by
# BURNIN's own list order -- test1 test2 test3 test1 test2 test1 test2 test1
# test1 ... -- checked by actually driving the real script through repeated
# cycles rather than asserting against a description of what it should do.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NODE=testnode
stub="$work/bin"
mkdir -p "$stub"

cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "show node")      printf 'NodeName=%s State=IDLE Reason=none\n' "$3"; exit 0 ;;
    "show hostnames") printf '%s\n' "$3"; exit 0 ;;
esac
[[ "$1" == "listjobs" ]] && printf 'JOBID\n'
exit 0
EOF
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$stub/sbatch" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/sbatch.calls"
printf 'Submitted batch job 90001\n'
exit 0
EOF
cat > "$stub/scancel" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$stub/su" <<'EOF'
#!/bin/bash
cmd=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-c" ]] && cmd="$a"
    prev="$a"
done
exec bash -c "$cmd"
EOF
chmod 755 "$stub"/*

## The stub tree. Three burn-in fixture jobs: test1 (STEP_TIMELIMIT only, the
## fallback), test2 and test3 (--time_to_run, the primary path).
tree="$work/tree"
mkdir -p "$tree/jobs/nvl72" "$tree/parsers/nvl72" "$tree/results/$NODE"
cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" \
   "$repo/slurm-snapshot.sh" "$repo/fanout.sh" "$repo/verdict-scan.sh" \
   "$repo/report_job-status.sh" "$tree/"
cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"

cat > "$tree/jobs/nvl72/test1.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=10
STEP_TIMELIMIT=1:00:00
echo PENDING
EOF
cat > "$tree/jobs/nvl72/test2.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=3
STEP_TIMELIMIT=0:30:00
  --time_to_run 3600 \
echo PENDING
EOF
cat > "$tree/jobs/nvl72/test3.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=1
STEP_TIMELIMIT=0:30:00
  --time_to_run 7200 \
echo PENDING
EOF

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

logs="$tree/results/$NODE"
write_view() {
    {
        printf 'stamp\t%s\n' "$(date +%s)"
        printf 'state\tidle\nsetter\tnone\nwhen\t\n'
        printf 'gres\tgpu:gb200:4\ncputot\t72\nfleet\t0\n'
        printf 'reason\t\n'
        printf 'end\t%s\n' "$(date +%s)"
    } > "$logs/.slurm-view"
}

## One cycle: writes the view, runs the real script, returns what it decided
## to submit ("<job> run <r>", or empty if nothing was).
run_cycle() {
    write_view
    (
        export PATH="$stub:$PATH" STUB_DIR="$tree" HOME="$work"
        export HOSTNAME="$NODE" LAUNCH_JOB_HOME="$tree"
        "$repo/actions/launch_job.sh" --quiet
    ) > "$tree/out" 2>&1
    grep -oE 'submitted [a-z0-9]+ run [0-9]+' "$logs/trigger.log" | tail -1 | sed 's/^submitted //'
}

## Marks the just-submitted run as passed, so the next cycle's fairness pick
## sees it. Mirrors what a real sbatch run would leave behind.
mark_passed() {
    local job="$1" run="$2" total="$3" file
    if [[ "$total" -eq 1 ]]; then file="$logs/$job.txt"; else file="$logs/$job-run${run}.txt"; fi
    printf 'ok\nPENDING\n' > "$file"
}

echo "== the worked example: fewest passed first, ties by BURNIN order =="

cat > "$tree/SETTINGS" <<EOF
JOBS=nvl72
HEALTHCHECKS=nvl72
PARSERS=nvl72
BRINGUP_DATA=$tree
BENCHMARKS=""
BURNIN="test1 test2 test3"
RUN_BURNIN=yes
BURNIN_HOURS=1000
NODE_FILTER=""
CONTAINERS=""
RUN_JOBS=yes
RUN_HEALTH_CHECKS=yes
RUN_CONTAINER_COPY=yes
RUN_RECOVERY=no
DRAIN_AFTER_FAILED_BENCHMARK=no
RECOVER_SLURM_DRAINS=no
RETRY_INTERVAL_HOURS=1
MAX_JOB_HOURS=7
INFLIGHT_GRACE_MINUTES=30
GET_OUT_OF_THE_WAY=no
JOB_USER=$(id -un)
LLMB_INSTALL=
EOF

declare -A totals=([test1]=10 [test2]=3 [test3]=1)
sequence=""
for _ in $(seq 1 10); do
    picked=$(run_cycle)
    [[ -n "$picked" ]] || { bad "cycle produced no submission: $(cat "$tree/out")"; break; }
    job="${picked%% *}"; run="${picked##* }"
    sequence+="${sequence:+ }$job"
    mark_passed "$job" "$run" "${totals[$job]}"
done

want="test1 test2 test3 test1 test2 test1 test2 test1 test1 test1"
if [[ "$sequence" == "$want" ]]; then
    ok "sequence matches the worked example: $sequence"
else
    bad "sequence: got [$sequence] want [$want]"
fi

echo "== tie-break follows BURNIN's own order, not job name =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BURNIN=.*/BURNIN="test3 test2 test1"/' "$tree/SETTINGS"
picked=$(run_cycle)
[[ "$picked" == "test3 run 1" ]] &&
    ok "reordering BURNIN moves the first pick with it: $picked" ||
    bad "tie-break did not follow the reordered list: $picked"
sed -i 's/^BURNIN=.*/BURNIN="test1 test2 test3"/' "$tree/SETTINGS"

echo "== job_run_seconds: --time_to_run, and the STEP_TIMELIMIT fallback =="

rm -rf "$logs"; mkdir -p "$logs"
## test1 has no --time_to_run, so one passed run credits STEP_TIMELIMIT's
## 1:00:00 -- 1 hour, not 0.
mark_passed test1 1 10
picked=$(run_cycle)
[[ "$picked" == "test2 run 1" ]] &&
    ok "test1's single passed run did not re-select test1 immediately: $picked" ||
    bad "unexpected pick after seeding test1: $picked"
## STEP_TIMELIMIT's 1:00:00 credited as 1 hour is checked directly against
## the report in the "report" section below, once test2 has a passed run too.

echo "== BURNIN_HOURS: the shared target stops every job, not just one =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BURNIN_HOURS=.*/BURNIN_HOURS=1/' "$tree/SETTINGS"
## One passed run of test1 (STEP_TIMELIMIT fallback, 1h) already meets a 1h
## target on its own.
mark_passed test1 1 10
picked=$(run_cycle)
if [[ -z "$picked" ]]; then
    ok "no further submission once BURNIN_HOURS is met"
else
    bad "submitted $picked after BURNIN_HOURS should have closed the gate"
fi
grep -q 'reached' "$logs/trigger.log" && ok "the gate traced why it closed" ||
    bad "no 'reached' trace line: $(cat "$logs/trigger.log" 2>/dev/null)"

echo "== stuck: every job at its own totalRuns cap, target still open =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BURNIN=.*/BURNIN="test3"/' "$tree/SETTINGS"
sed -i 's/^BURNIN_HOURS=.*/BURNIN_HOURS=1000/' "$tree/SETTINGS"
mark_passed test3 1 1
picked=$(run_cycle)
[[ -z "$picked" ]] && ok "nothing submitted -- test3 is at its own cap" ||
    bad "submitted $picked with test3 already at totalRuns=1"
if grep -q 'cannot be reached' "$logs/trigger.log"; then
    ok "traced as unreachable, not as the generic nothing-eligible line"
else
    bad "no distinguishing trace line: $(cat "$logs/trigger.log" 2>/dev/null)"
fi
sed -i 's/^BURNIN=.*/BURNIN="test1 test2 test3"/' "$tree/SETTINGS"

echo "== report: burnin_hours_cell, no -run columns for BURNIN jobs =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BURNIN_HOURS=.*/BURNIN_HOURS=1000/' "$tree/SETTINGS"
mark_passed test1 1 10
mark_passed test2 1 3
report_out=$(
    export PATH="$stub:$PATH" HOME="$work"
    cd "$tree" && ./report_job-status.sh 2>/dev/null
)
if grep -q '2H/1000H' <<<"$report_out"; then
    ok "report_job-status.sh reports 2H/1000H (test1's 1h + test2's 1h)"
else
    bad "report_job-status.sh did not report the expected hour total: $report_out"
fi
if grep -qE 'test[123]-run[0-9]+' <<<"$report_out"; then
    bad "a -run column for a BURNIN job survived in the report"
else
    ok "no -run columns for BURNIN jobs"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

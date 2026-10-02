#!/bin/bash
#
# actions/launch_job.sh: CONTINUE_RUNNING_JOBS / CONTINUE_RUNNING_FREQUENCY,
# the third and lowest scheduling tier below BENCHMARKS and BURNIN.
#
# Issue #5: jobs listed here re-run on a flat cadence once they are DONE,
# ignoring totalRuns entirely -- one slot, forever. A failure needs no new
# code to hand priority back: the normal survey() of BENCHMARKS/BURNIN reads
# the same result file, and being strictly higher priority reclaims the whole
# tier the moment it sees a failed result. See
# docs/explanation/sequencing.md#continuous-re-runs.

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

## The stub tree. test1/test2 are the continue-running pair; mnu mirrors a
## burn-in-shaped job (totalRuns > 1) to prove it is ignored.
tree="$work/tree"
mkdir -p "$tree/jobs/nvl72" "$tree/parsers/nvl72" "$tree/results/$NODE"
cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" \
   "$repo/slurm-snapshot.sh" "$repo/fanout.sh" "$repo/verdict-scan.sh" \
   "$repo/report_job-status.sh" "$tree/"
cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"

cat > "$tree/jobs/nvl72/test1.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=1
echo PENDING
EOF
cat > "$tree/jobs/nvl72/test2.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=1
echo PENDING
EOF
cat > "$tree/jobs/nvl72/mnu.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=12
echo PENDING
EOF
cat > "$tree/jobs/nvl72/orphan.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
totalRuns=1
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

## Single-slot result, backdated by $age_secs so CONTINUE_RUNNING_FREQUENCY's
## staleness check can be driven directly instead of sleeping.
seed_result() {
    local verdict="$2" age_secs="${3:-0}" file="$logs/$1.txt"
    printf 'ok\n%s\n' "$verdict" > "$file"
    [[ "$age_secs" -gt 0 ]] && touch -d "@$(( $(date +%s) - age_secs ))" "$file"
}

base_settings() {
    cat > "$tree/SETTINGS" <<EOF
JOBS=nvl72
HEALTHCHECKS=nvl72
PARSERS=nvl72
BRINGUP_DATA=$tree
BENCHMARKS=""
BURNIN=""
RUN_BURNIN=no
CONTINUE_RUNNING_JOBS="test1 test2"
CONTINUE_RUNNING_FREQUENCY=6
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
}

echo "== a missing result is due immediately, in list order =="

base_settings
picked=$(run_cycle)
[[ "$picked" == "test1 run 1" ]] &&
    ok "test1 picked first, list order: $picked" ||
    bad "unexpected first pick: $picked ($(cat "$tree/out"))"

echo "== a fresh result is not due =="

rm -rf "$logs"; mkdir -p "$logs"
seed_result test1 DONE 0
seed_result test2 DONE 0
picked=$(run_cycle)
[[ -z "$picked" ]] &&
    ok "nothing submitted -- both results are fresh" ||
    bad "submitted $picked with both results fresh"

echo "== a stale result is due again, single slot (no -run column) =="

rm -rf "$logs"; mkdir -p "$logs"
seed_result test1 DONE 21600
seed_result test2 DONE 0
picked=$(run_cycle)
[[ "$picked" == "test1 run 1" ]] &&
    ok "test1 re-picked once past CONTINUE_RUNNING_FREQUENCY: $picked" ||
    bad "unexpected pick with test1 stale: $picked"

echo "== totalRuns is ignored: always one slot, never a -run<N> file =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^CONTINUE_RUNNING_JOBS=.*/CONTINUE_RUNNING_JOBS="mnu"/' "$tree/SETTINGS"
picked=$(run_cycle)
[[ "$picked" == "mnu run 1" ]] &&
    ok "mnu (totalRuns=12) picked as run 1: $picked" ||
    bad "unexpected pick for totalRuns=12 job: $picked"
if grep -q -- "--output=$logs/mnu.txt" "$tree/sbatch.calls"; then
    ok "submitted against single-slot mnu.txt, not mnu-run1.txt"
else
    bad "sbatch was not given mnu.txt as --output: $(cat "$tree/sbatch.calls")"
fi
grep -q -- "--output=$logs/mnu-run1.txt" "$tree/sbatch.calls" &&
    bad "sbatch was given a -run1 output for a continue-running job"
sed -i 's/^CONTINUE_RUNNING_JOBS=.*/CONTINUE_RUNNING_JOBS="test1 test2"/' "$tree/SETTINGS"

echo "== BENCHMARKS pending blocks the whole tier =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BENCHMARKS=.*/BENCHMARKS="orphan"/' "$tree/SETTINGS"
seed_result test1 DONE 21600
seed_result test2 DONE 21600
picked=$(run_cycle)
[[ "$picked" == "orphan run 1" ]] &&
    ok "BENCHMARKS' own job ran instead: $picked" ||
    bad "expected orphan (BENCHMARKS) to run first, got: $picked"
sed -i 's/^BENCHMARKS=.*/BENCHMARKS=""/' "$tree/SETTINGS"

echo "== a failure hands priority back to the normal BENCHMARKS path =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^BENCHMARKS=.*/BENCHMARKS="test1"/' "$tree/SETTINGS"
sed -i 's/^CONTINUE_RUNNING_FREQUENCY=.*/CONTINUE_RUNNING_FREQUENCY=1000/' "$tree/SETTINGS"
sed -i 's/^RETRY_INTERVAL_HOURS=.*/RETRY_INTERVAL_HOURS=1/' "$tree/SETTINGS"
seed_result test1 FAIL 7200
seed_result test2 DONE 0
picked=$(run_cycle)
[[ "$picked" == "test1 run 1" ]] &&
    ok "the failed job was retried via BENCHMARKS, not CONTINUE_RUNNING_FREQUENCY: $picked" ||
    bad "expected BENCHMARKS to reclaim the failed job, got: $picked"
sed -i 's/^BENCHMARKS=.*/BENCHMARKS=""/' "$tree/SETTINGS"
sed -i 's/^CONTINUE_RUNNING_FREQUENCY=.*/CONTINUE_RUNNING_FREQUENCY=6/' "$tree/SETTINGS"

echo "== orphaned entry: not in BENCHMARKS or BURNIN =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i 's/^CONTINUE_RUNNING_JOBS=.*/CONTINUE_RUNNING_JOBS="test1 orphan"/' "$tree/SETTINGS"
run_cycle >/dev/null
if grep -q 'WARNING: CONTINUE_RUNNING_JOBS names orphan' "$logs/trigger.log"; then
    ok "orphaned entry warned about by name"
else
    bad "no orphaned-entry warning: $(cat "$logs/trigger.log" 2>/dev/null)"
fi
sed -i 's/^CONTINUE_RUNNING_JOBS=.*/CONTINUE_RUNNING_JOBS="test1 test2"/' "$tree/SETTINGS"

echo "== off by default: unset entirely, no behavior change, no trace noise =="

rm -rf "$logs"; mkdir -p "$logs"
sed -i '/^CONTINUE_RUNNING_JOBS=/d; /^CONTINUE_RUNNING_FREQUENCY=/d' "$tree/SETTINGS"
picked=$(run_cycle)
[[ -z "$picked" ]] &&
    ok "nothing submitted with the setting unset and BENCHMARKS/BURNIN empty" ||
    bad "unexpected submission with the feature unset: $picked"
if grep -q 'CONTINUE_RUNNING_JOBS' "$logs/trigger.log"; then
    bad "trace noise from an unset feature: $(cat "$logs/trigger.log")"
else
    ok "no trace mentions CONTINUE_RUNNING_JOBS when it is unset"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

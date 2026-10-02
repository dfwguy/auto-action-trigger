#!/bin/bash
#
# Checks that archive_result() in actions/launch_job.sh never overwrites a
# result in place -- the promise docs/explanation/sequencing.md and
# verdicts-and-the-cache.md both make, and issue #10 asked to see proven.
#
# A passing result that --all re-queues has to survive under .prevN.txt, a
# second --all has to add .prev2.txt without touching .prev1.txt, and a
# failure has to stay in the separate .failN.txt series -- the two counters
# are independent by design (see archive_result()'s comment), so a bug that
# merged them would still pass a test that only checked one series existed.
# report_job-status.sh is also driven against the archive it is left with, since a
# filename nobody reads correctly is not actually preserving anything.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NODE=testnode
stub="$work/bin"
mkdir -p "$stub"

cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
case "$1 $2" in
    "show node")      printf 'NodeName=%s State=IDLE Reason=none\n' "$3"; exit 0 ;;
    "show hostnames") printf '%s\n' "$3"; exit 0 ;;
esac
[[ "$1" == "listjobs" ]] && printf 'JOBID\n'
exit 0
EOF

cat > "$stub/squeue" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/squeue.calls"
exit 0
EOF

## Just needs to succeed and hand back a job id -- no case here depends on the
## job actually running, only on what submit_one() did to the result file
## before it submitted.
cat > "$stub/sbatch" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/sbatch.calls"
if [[ -f "$STUB_DIR/sbatch.fail" ]]; then
    printf 'sbatch: error: Socket timed out on send/recv operation\n' >&2
    exit 1
fi
printf 'Submitted batch job 90001\n'
exit 0
EOF

cat > "$stub/scancel" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scancel.calls"
exit 0
EOF

cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/sinfo.calls"
exit 0
EOF

## Same reason as tests/inflight-test.sh: a submission as root reaches JOB_USER
## through `su -l -c`, and a login shell rebuilds PATH from /etc/profile,
## dropping every stub above.
cat > "$stub/su" <<'EOF'
#!/bin/bash
cmd=""; prev=""
for a in "$@"; do
    [[ "$prev" == "-c" ]] && cmd="$a"
    prev="$a"
done
printf '%s\n' "$cmd" >> "$STUB_DIR/su.calls"
exec bash -c "$cmd"
EOF

chmod 755 "$stub"/*

## The stub tree: the real settings loader, parser and fan-out/scan libraries,
## a job whose verdict comes from the generic gate, and report_job-status.sh itself
## so the archive it leaves behind is read the same way a real report would.
tree="$work/tree"
mkdir -p "$tree/jobs/nvl72" "$tree/parsers/nvl72" "$tree/results/$NODE"
cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" \
   "$repo/slurm-snapshot.sh" "$repo/fanout.sh" "$repo/verdict-scan.sh" \
   "$repo/report_job-status.sh" "$tree/"
cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"

cat > "$tree/jobs/nvl72/probe.sbatch" <<'EOF'
#!/bin/bash
#SBATCH -t 00:20:00
#SBATCH --exclusive
echo PENDING
EOF

cat > "$tree/SETTINGS" <<EOF
JOBS=nvl72
HEALTHCHECKS=nvl72
PARSERS=nvl72
BRINGUP_DATA=$tree
BENCHMARKS="probe"
NODE_FILTER=""
RUN_BURNIN=no
BURNIN=""
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

printf 'export PATH="%s:$PATH"\n' "$stub" > "$work/.bash_profile"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

logs=""
CASE_DIR=""
setup=""

## The generic gate's whole rule is an end marker -- a passing result, as far
## as this test needs to go.
result_pass() { printf 'run %s\nPENDING\n' "$1" > "$logs/probe.txt"; }
## No end marker and no run error -- rejected by the generic gate.
result_fail() { printf 'run %s\n' "$1" > "$logs/probe.txt"; }

## The watchdog's node view launch_job.sh reads instead of asking Slurm
## directly -- no marker means "not known", which fails towards not
## submitting. An idle node with nothing of ours queued, same shape as
## tests/inflight-test.sh's write_view().
write_view() {
    {
        printf 'stamp\t%s\n' "$(date +%s)"
        printf 'state\tidle\n'
        printf 'setter\tnone\n'
        printf 'when\t\n'
        printf 'gres\tgpu:gb200:4\n'
        printf 'cputot\t72\n'
        printf 'fleet\t0\n'
        printf 'reason\t\n'
        printf 'end\t%s\n' "$(date +%s)"
    } > "$logs/.slurm-view"
}

## One launch_job.sh run against a fresh copy of the tree. $1 name, $2 the
## force flag (--all or --force). $setup runs first, with $logs already
## pointed at the case's results dir, same convention as inflight-test.sh.
run_launch() {
    local name="$1" flag="$2"
    CASE_DIR="$work/case-$((pass + fail))"
    cp -r "$tree" "$CASE_DIR"
    sed -i "s#^BRINGUP_DATA=.*#BRINGUP_DATA=$CASE_DIR#" "$CASE_DIR/SETTINGS"
    logs="$CASE_DIR/results/$NODE"
    eval "$setup"
    write_view
    (
        export PATH="$stub:$PATH" STUB_DIR="$CASE_DIR" HOME="$work"
        export HOSTNAME="$NODE" LAUNCH_JOB_HOME="$CASE_DIR"
        "$repo/actions/launch_job.sh" "$flag" --quiet
    ) > "$CASE_DIR/out" 2>&1
    setup=""
    printf '%s\n' "$name"
}

## A second launch_job.sh run in the SAME case directory, so it is checked
## against what the previous run left behind rather than a fresh tree. $setup
## seeds the next result before this run, as above.
rerun_launch() {
    local flag="$1"
    eval "$setup"
    write_view
    (
        export PATH="$stub:$PATH" STUB_DIR="$CASE_DIR" HOME="$work"
        export HOSTNAME="$NODE" LAUNCH_JOB_HOME="$CASE_DIR"
        "$repo/actions/launch_job.sh" "$flag" --quiet
    ) >> "$CASE_DIR/out" 2>&1
    setup=""
}

archived()   { [[ -f "$logs/probe.$1.txt" ]]; }
content_is() { [[ -f "$logs/probe.$1.txt" ]] && grep -qF "$2" "$logs/probe.$1.txt"; }
submitted()  { [[ -f "$CASE_DIR/sbatch.calls" ]]; }
check() { # $1 description, $2 command
    if eval "$2"; then ok "$1"; else bad "$1"; sed 's/^/       /' "$logs/trigger.log" 2>/dev/null; fi
}

echo "== a passing result survives --all =="

setup='result_pass first'
run_launch "seeded DONE, forced with --all" --all >/dev/null
check "current result file is gone (archived, not overwritten)" '[[ ! -f "$logs/probe.txt" ]]'
check "archived as .prev1, not .fail1"      'archived prev1 && ! archived fail1'
check "the archive kept the original content" 'content_is prev1 "run first"'
check "a new attempt was submitted"         'submitted'

echo "== a second forced run does not touch the first archive =="

setup='result_pass second'
rerun_launch --all
check ".prev2 holds the second result"   'content_is prev2 "run second"'
check ".prev1 is untouched"              'content_is prev1 "run first"'
check "both archives coexist"            'archived prev1 && archived prev2'

echo "== a failed result stays in the .failN series, not .prevN =="

setup='result_fail first'
run_launch "seeded FAIL, forced with --force" --force >/dev/null
check "archived as .fail1, not .prev1" 'archived fail1 && ! archived prev1'
check "a new attempt was submitted"    'submitted'

echo "== report_job-status.sh reads a --all archive as RERUNNING, not FAIL =="

setup='result_pass only'
run_launch "seeded DONE for the report case" --all >/dev/null
report_out="$CASE_DIR/report.out"
( cd "$CASE_DIR" && ./report_job-status.sh ) > "$report_out" 2>/dev/null
if grep -q 'RERUNNING' "$report_out" && grep -qi "$NODE" "$report_out"; then
    ok "report_job-status.sh reports the re-queued column as RERUNNING"
else
    bad "report_job-status.sh did not report RERUNNING for the re-queued column"
    sed 's/^/       /' "$report_out"
fi
grep -q 'FAIL' "$report_out" &&
    bad "  ... and it also reported FAIL for a result that passed before being re-queued" ||
    ok "  ... and it did not misreport the pass as a failure"

echo "== an sbatch error backs off without losing an accepted job =="

setup='touch "$CASE_DIR/sbatch.fail"'
run_launch "sbatch times out" --force >/dev/null
check "the failure is traced" 'grep -q "SUBMIT FAILED probe run 1: sbatch exited 1:" "$logs/trigger.log" && grep -q "Socket timed out" "$logs/trigger.log"'
check "a durable submission retry is recorded" '[[ -f "$logs/.submit-retry" ]]'
check "a failed submission has no in-flight marker" '[[ ! -f "$logs/.in-flight" ]]'
check "sbatch was called once" '[[ "$(wc -l < "$CASE_DIR/sbatch.calls")" -eq 1 ]]'

rerun_launch --force
check "the next cycle does not call sbatch again" '[[ "$(wc -l < "$CASE_DIR/sbatch.calls")" -eq 1 ]]'
check "the backoff is traced with Slurm's error" 'grep -q "EXIT: submission backoff" "$logs/trigger.log" && grep -q "Socket timed out" "$logs/trigger.log"'

## Even an elapsed clock cannot open the retry until a snapshot newer than the
## ambiguous sbatch has allowed the ordinary duplicate guard to see it.
IFS=$'\t' read -r _ _ retry_fails retry_job retry_run retry_total retry_rc retry_diag < "$logs/.submit-retry"
printf '%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) + 60 ))" \
    "$retry_fails" "$retry_job" "$retry_run" "$retry_total" "$retry_rc" "$retry_diag" > "$logs/.submit-retry"
touch -d '@2147483647' "$logs/.submit-retry"
rerun_launch --force
check "an old snapshot does not reopen an ambiguous submission" '[[ "$(wc -l < "$CASE_DIR/sbatch.calls")" -eq 1 ]]'
check "the snapshot wait is traced" 'grep -q "node view is not newer than the failed sbatch" "$logs/trigger.log"'

## A later watchdog view makes the retry safe; success clears retry state and
## writes the usual in-flight marker.
printf '%s\t0\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 60 ))" \
    "$retry_fails" "$retry_job" "$retry_run" "$retry_total" "$retry_rc" "$retry_diag" > "$logs/.submit-retry"
touch -d '@946684800' "$logs/.submit-retry"
rm -f "$CASE_DIR/sbatch.fail"
rerun_launch --force
check "sbatch is retried after a fresh snapshot" '[[ "$(wc -l < "$CASE_DIR/sbatch.calls")" -eq 2 ]]'
check "success clears submission retry state" '[[ ! -f "$logs/.submit-retry" ]]'
check "success writes the accepted job id" 'grep -q "^90001" "$logs/.in-flight"'

echo "== a fleet submission circuit stops node-local sbatch =="

setup='printf "%s\\t%s\\t12\\tsbatch: error: controller unavailable\\n" "$(date +%s)" "$(( $(date +%s) + 600 ))" > "$CASE_DIR/results/.submit-circuit"'
run_launch "fleet circuit is open" --force >/dev/null
check "the open circuit prevents submission" '! submitted'
check "the fleet hold is traced" 'grep -q "EXIT: fleet submission circuit is open" "$logs/trigger.log"'

echo "== a leftover PAUSE_JOBS is not silently ignored =="

printf 'PAUSE_JOBS=yes\n' >> "$tree/SETTINGS"
setup='result_pass first'
run_launch "old name still in SETTINGS" --all >/dev/null
if grep -q 'PAUSE_JOBS' "$logs/trigger.log"; then
    ok "the rename is traced -- an operator would see it, not silence"
else
    bad "a leftover PAUSE_JOBS produced no trace at all"
fi
sed -i '/^PAUSE_JOBS=yes$/d' "$tree/SETTINGS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

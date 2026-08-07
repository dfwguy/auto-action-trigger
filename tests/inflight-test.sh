#!/bin/bash
#
# Checks the in-flight gate in actions/launch_job.sh -- the branch that decides
# whether this node already has a job out -- against a stubbed Slurm and a stub
# tree. The script under test is the real one, run with LAUNCH_JOB_HOME.
#
# The gate had no coverage until a `NOT_RUN` result file made it delete the
# marker of every job that had not started yet, so the cases below are mostly
# about what must NOT happen: no marker deleted on a guess, no second job
# submitted when the controller would not say what is queued.
# See docs/explanation/sequencing.md#a-missing-result-file-is-not-a-finished-job.

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

NODE=testnode
stub="$work/bin"
mkdir -p "$stub"

## `listjobs` is the local question -- which jobs are running on this node --
## and the only one answered without the controller.
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
case "$1 $2" in
    "show node")      printf 'NodeName=%s State=IDLE Reason=none\n' "$3"; exit 0 ;;
    "show hostnames") printf '%s\n' "$3"; exit 0 ;;
esac
if [[ "$1" == "listjobs" ]]; then
    printf 'JOBID\n'
    [[ -n "$STUB_LOCAL_JOBS" ]] && printf '%s\n' $STUB_LOCAL_JOBS
fi
exit 0
EOF

## Two questions, told apart the way the script asks them: one job by id in the
## stale branch, and the whole queue in the guard before a submission. Either
## can be made to fail, which is the case that matters.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/squeue.calls"
case "$*" in
    *-j*)
        if [[ -n "$STUB_SQUEUE_J_FAIL" ]]; then
            printf 'slurm_load_jobs error: Socket timed out on send/recv operation\n' >&2
            exit 1
        fi
        if [[ -n "$STUB_SQUEUE_J_INVALID" ]]; then
            printf 'slurm_load_jobs error: Invalid job id specified\n' >&2
            exit 1
        fi
        [[ -n "$STUB_SQUEUE_J" ]] && printf '%s\n' "$STUB_SQUEUE_J"
        exit 0 ;;
    *-n*)
        exit 0 ;;
    *)
        if [[ -n "$STUB_QUEUE_FAIL" ]]; then
            printf 'slurm_load_jobs error: Unable to contact slurm controller\n' >&2
            exit 1
        fi
        [[ -n "$STUB_QUEUE" ]] && printf '%s\n' "$STUB_QUEUE"
        exit 0 ;;
esac
EOF

cat > "$stub/sbatch" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/sbatch.calls"
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
printf '%s|idle|none\n' "$3"
exit 0
EOF

chmod 755 "$stub"/*

## The stub tree: the real settings loader and the real parser, a job whose
## walltime the gate reads, and nothing else.
tree="$work/tree"
mkdir -p "$tree/jobs/nvl72" "$tree/parsers/nvl72" "$tree/results/$NODE"
cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" "$tree/"
cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"

## `probe` takes the generic gate rather than a bandwidth one, so a result file
## is judged on its end marker alone.
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
BENCHMARKS="probe"
NODE_FILTER=""
RUN_BURNIN=no
BURNIN=""
CONTAINERS=""
PAUSE_JOBS=no
PAUSE_HEALTH_CHECKS=no
PAUSE_CONTAINER_COPY=no
PAUSE_RECOVERY=yes
DRAIN_AFTER_FAILED_BENCHMARK=no
RECOVER_SLURM_DRAINS=no
MAX_QUEUED_JOBS=0
RETRY_INTERVAL_HOURS=1
MAX_JOB_HOURS=7
INFLIGHT_GRACE_MINUTES=30
GET_OUT_OF_THE_WAY=no
JOB_USER=$(id -un)
LLMB_INSTALL=
EOF

## `bash -lc` is how a submission reaches $JOB_USER, and a login shell rebuilds
## PATH from /etc/profile -- which would drop the stubs. HOME's profile is read
## after it, so this is where the stubs are put back.
printf 'export PATH="%s:$PATH"\n' "$stub" > "$work/.bash_profile"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

logs=""
CASE_DIR=""
setup=""
## One case: $1 name, rest VAR=value for the stubs. $setup runs inside the case
## directory with $logs set, and is what seeds the marker and the result file.
run_case() {
    local name="$1"; shift
    CASE_DIR="$work/case-$((pass + fail))"
    cp -r "$tree" "$CASE_DIR"
    logs="$CASE_DIR/results/$NODE"

    (
        export PATH="$stub:$PATH" STUB_DIR="$CASE_DIR" HOME="$work"
        export HOSTNAME="$NODE" LAUNCH_JOB_HOME="$CASE_DIR"
        export STUB_LOCAL_JOBS="" STUB_QUEUE="" STUB_QUEUE_FAIL=""
        export STUB_SQUEUE_J="" STUB_SQUEUE_J_FAIL="" STUB_SQUEUE_J_INVALID=""
        for kv in "$@"; do export "${kv?}"; done
        eval "$setup"
        "$repo/actions/launch_job.sh" --quiet
    ) > "$CASE_DIR/out" 2>&1

    setup=""
    printf '%s\n' "$name"
}

## A marker for job 4242, $1 seconds old.
marker() {
    printf '4242\tprobe\t1\t1\t%s\n' "$(( $(date +%s) - $1 ))" > "$logs/.in-flight"
}
result_done()       { printf 'some output\nPENDING\n' > "$logs/probe.txt"; }
result_started()    { printf 'some output\n' > "$logs/probe.txt"; }

traced()      { grep -qF "$1" "$logs/trigger.log" 2>/dev/null; }
marker_kept() { [[ -f "$logs/.in-flight" ]]; }
submitted()   { [[ -f "$CASE_DIR/sbatch.calls" ]]; }
check() { # $1 description, $2 command
    if eval "$2"; then ok "$1"; else bad "$1"; sed 's/^/       /' "$logs/trigger.log" 2>/dev/null; fi
}

echo "== a job that has been submitted but has not started =="

## The bug: no result file exists until the job starts, and NOT_RUN was read as
## "finished". The marker must outlive it.
setup='marker 40'
run_case "queued, no result file yet, inside its window" >/dev/null
check "marker kept"          'marker_kept'
check "traced as waiting"    'traced "not running here yet -- waiting"'
check "nothing submitted"    '! submitted'
check "controller not asked" '[[ ! -f "$CASE_DIR/squeue.calls" ]]'

setup='marker 40; result_started'
run_case "started, no end marker, inside its window" >/dev/null
check "marker kept"       'marker_kept'
check "traced as waiting" 'traced "not running here yet -- waiting"'

echo "== a job that has finished =="

setup='marker 300; result_done'
run_case "result file carries an end marker" >/dev/null
check "marker cleared"     '! marker_kept'
check "traced as finished" 'traced "finished after"'

setup='marker 40; STUB_LOCAL_JOBS=4242'
run_case "running here now" >/dev/null
check "marker kept"          'marker_kept'
check "traced as running"    'traced "running here for"'
check "controller not asked" '[[ ! -f "$CASE_DIR/squeue.calls" ]]'

echo "== past its walltime, so the controller is asked =="

## 20m walltime + 30m grace, so 4000s is past the bound.
setup='marker 4000; STUB_SQUEUE_J="PENDING Resources"'
run_case "still queued" >/dev/null
check "marker kept"        'marker_kept'
check "traced as queued"   'traced "still queued after"'
check "nothing submitted"  '! submitted'

## The marker is cleared and the cycle carries on to resubmit, so what proves
## the old one went is the new id in its place.
setup='marker 4000; STUB_SQUEUE_J_INVALID=1'
run_case "slurm has forgotten the job" >/dev/null
check "traced as gone"        'traced "is gone from the queue"'
check "resubmitted"           'submitted'
check "marker holds the new id" 'grep -q "^90001" "$logs/.in-flight"'

setup='marker 4000; STUB_SQUEUE_J_FAIL=1'
run_case "the controller would not answer" >/dev/null
check "marker kept"          'marker_kept'
check "traced as unanswered" 'traced "would not answer"'
check "nothing archived"     '[[ ! -f "$logs/probe.fail1.txt" ]]'
check "nothing submitted"    '! submitted'

setup='marker 4000; result_started; STUB_SQUEUE_J_FAIL=1'
run_case "unanswered, with a partial result on disk" >/dev/null
check "partial result untouched" '[[ -f "$logs/probe.txt" && ! -f "$logs/probe.fail1.txt" ]]'

echo "== the guard before a submission =="

run_case "no marker, nothing of ours queued" >/dev/null
check "submitted"            'submitted'
check "marker written"       'marker_kept'
check "id taken from sbatch" 'grep -q "^90001" "$logs/.in-flight"'

setup='STUB_QUEUE="4242 bringup-testnode"'
run_case "no marker, but a job of ours is queued" >/dev/null
check "nothing submitted" '! submitted'
check "traced"            'traced "no marker, but"'

## The other half of the duplicate: an unanswered query used to read as an
## empty queue, and an empty queue is a licence to submit.
setup='STUB_QUEUE_FAIL=1'
run_case "no marker, and the queue cannot be read" >/dev/null
check "nothing submitted" '! submitted'
check "traced"            'traced "the queue could not be read"'
check "no marker written" '! marker_kept'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

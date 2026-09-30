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

## Both questions this script used to ask the controller are answered from the
## node view now. The stubs stay on PATH and record: a case asserting the
## controller was not asked needs something that would have recorded it if it
## had been. See docs/explanation/the-fleet-snapshot.md.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/squeue.calls"
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
printf '%s\n' "$*" >> "$STUB_DIR/scancel.calls"
exit 0
EOF

cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/sinfo.calls"
exit 0
EOF

cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/systemctl.calls"
[[ -n "$STUB_INACTIVE_SERVICE" && "$*" == *"$STUB_INACTIVE_SERVICE"* ]] && exit 3
exit 0
EOF

cat > "$stub/timeout" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/timeout.calls"
[[ "$1" == "--foreground" ]] && shift
shift
exec "$@"
EOF

## A submission reaches $JOB_USER as `su - $JOB_USER -c <cmd>` when the cycle is
## root's, and a login shell rebuilds PATH from the system profile -- which
## drops every stub above. Stubbing the privilege drop keeps the command in this
## environment; CI runs as root, so without this the submitting cases test the
## runner's PATH rather than the sequencer.
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

## The stub tree: the real settings loader and the real parser, a job whose
## walltime the gate reads, and nothing else.
tree="$work/tree"
mkdir -p "$tree/jobs/nvl72" "$tree/parsers/nvl72" "$tree/results/$NODE"
cp "$repo/settings.sh" "$repo/reason-map.sh" "$repo/slurm-recovery.sh" \
   "$repo/slurm-snapshot.sh" "$tree/"
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

## The watchdog's node view, in place of the two squeues this script used to
## make. STUB_NO_VIEW is the "no answer" case -- a watchdog that has stopped, or
## a controller that would not say -- and every gate must fail towards not
## acting on it. See docs/explanation/the-fleet-snapshot.md#no-view-is-not-an-empty-queue.
##
## STUB_SQUEUE_J is `<state> <reason...>` for the job in the marker; STUB_QUEUE
## is `<id> <name>` per line for the guard before a submission. Both become the
## `ours` lines a node reads.
write_view() {
    [[ -n "$STUB_NO_VIEW" ]] && return 0
    {
        printf 'stamp\t%s\n'  "$(date +%s)"
        printf 'state\t%s\n' "${STUB_STATE:-idle}"
        printf 'setter\tnone\n'
        printf 'when\t\n'
        printf 'gres\tgpu:gb200:4\n'
        printf 'cputot\t72\n'
        printf 'fleet\t0\n'
        if [[ -n "$STUB_SQUEUE_J" ]]; then
            printf 'ours\t4242\t%s\tbringup-%s\t%s\n' \
                   "${STUB_SQUEUE_J%% *}" "$NODE" "${STUB_SQUEUE_J#* }"
        fi
        while read -r _id _name; do
            [[ -n "$_id" ]] && printf 'ours\t%s\tPENDING\t%s\tResources\n' "$_id" "$_name"
        done <<< "$STUB_QUEUE"
        printf 'reason\t\n'
        printf 'end\t%s\n' "$(date +%s)"
    } > "$logs/.slurm-view"
}
## One case: $1 name, rest VAR=value for the stubs. $setup runs inside the case
## directory with $logs set, and is what seeds the marker and the result file.
run_case() {
    local name="$1"; shift
    CASE_DIR="$work/case-$((pass + fail))"
    cp -r "$tree" "$CASE_DIR"
    sed -i "s#^BRINGUP_DATA=.*#BRINGUP_DATA=$CASE_DIR#" "$CASE_DIR/SETTINGS"
    logs="$CASE_DIR/results/$NODE"

    (
        export PATH="$stub:$PATH" STUB_DIR="$CASE_DIR" HOME="$work"
        export HOSTNAME="$NODE" LAUNCH_JOB_HOME="$CASE_DIR"
        export STUB_LOCAL_JOBS="" STUB_QUEUE="" STUB_NO_VIEW=""
        export STUB_SQUEUE_J="" STUB_STATE="" STUB_INACTIVE_SERVICE=""
        export STUB_EXPLAIN=""
        for kv in "$@"; do export "${kv?}"; done
        eval "$setup"
        write_view
        launch_args=()
        [[ -n "$STUB_EXPLAIN" ]] && launch_args+=(--explain)
        "$repo/actions/launch_job.sh" "${launch_args[@]}" --quiet
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

echo "== the BCM bootstrap gate is opt-in and bounded =="

run_case "the default does not probe BCM" >/dev/null
check "default off: a job was submitted" 'submitted'
check "default off: BCM's command service was not probed" \
    '! grep -qF "is-active --quiet cmd.service" "$CASE_DIR/systemctl.calls" 2>/dev/null'

run_case "opted in before the command URL exists" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    "LAUNCH_JOB_BCM_CMD_URL=$work/missing.cmd.url" >/dev/null
check "opted in: a missing URL defers submission" '! submitted'
check "opted in: the missing URL is named" 'traced "$work/missing.cmd.url"'

printf 'https://bcm-command.example.invalid\n' > "$work/my.cmd.url"
run_case "opted in after BCM is ready" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    BCM_BOOTSTRAP_PROBE_TIMEOUT_SECS=2 \
    "LAUNCH_JOB_BCM_CMD_URL=$work/my.cmd.url" >/dev/null
check "BCM ready: a job was submitted" 'submitted'
check "BCM ready: command probes use the configured bound" \
    '[[ "$(grep -cF -- "--foreground 2s" "$CASE_DIR/timeout.calls")" -eq 3 ]]'
check "BCM ready: the command service was probed" \
    'grep -qF "is-active --quiet cmd.service" "$CASE_DIR/systemctl.calls"'
check "BCM ready: the Slurm service was probed" \
    'grep -qF "is-active --quiet slurmd.service" "$CASE_DIR/systemctl.calls"'

run_case "opted in while cmd.service is inactive" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    "LAUNCH_JOB_BCM_CMD_URL=$work/my.cmd.url" \
    STUB_INACTIVE_SERVICE=cmd.service >/dev/null
check "inactive service: submission is deferred" '! submitted'
check "inactive service: cmd.service is named" 'traced "cmd.service"'

run_case "explain while BCM is not ready" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    "LAUNCH_JOB_BCM_CMD_URL=$work/missing.cmd.url" \
    STUB_EXPLAIN=1 >/dev/null
check "explain: the BCM blocker is named" 'traced "node bootstrap is not ready"'
check "explain: the real cycle's stop is named" \
    'traced "explaining anyway; a real cycle would stop here"'
check "explain: downstream gates are still evaluated" 'traced "WOULD SUBMIT"'
check "explain: nothing was submitted" '! submitted'

setup='printf "\nRUN_JOBS=no\n" >> "$CASE_DIR/SETTINGS"'
run_case "paused while BCM is not ready" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    "LAUNCH_JOB_BCM_CMD_URL=$work/missing.cmd.url" >/dev/null
check "paused: a real cycle does not probe BCM" \
    '! grep -qF "is-active --quiet cmd.service" "$CASE_DIR/systemctl.calls" 2>/dev/null'
check "paused: RUN_JOBS remains the stopping gate" 'traced "EXIT: RUN_JOBS=no"'

setup='printf "\nRUN_JOBS=no\n" >> "$CASE_DIR/SETTINGS"'
run_case "explain through a pause while BCM is not ready" \
    REQUIRE_BCM_BOOTSTRAP_READY=yes \
    "LAUNCH_JOB_BCM_CMD_URL=$work/missing.cmd.url" \
    STUB_EXPLAIN=1 >/dev/null
check "paused explain: BCM is still inspected" \
    'grep -qF "is-active --quiet cmd.service" "$CASE_DIR/systemctl.calls"'
check "paused explain: both blockers are named" \
    'traced "node bootstrap is not ready" && traced "RUN_JOBS=no"'
check "paused explain: downstream gates are still evaluated" 'traced "WOULD SUBMIT"'

echo "== a job that has been submitted but has not started =="

## The bug: no result file exists until the job starts, and NOT_RUN was read as
## "finished". The marker must outlive it.
setup='marker 40'
run_case "queued, no result file yet, inside its window" >/dev/null
check "marker kept"          'marker_kept'
check "traced as waiting"    'traced "not running here yet -- waiting"'
check "nothing submitted"    '! submitted'
check "controller not asked" '[[ ! -f "$CASE_DIR/squeue.calls" && ! -f "$CASE_DIR/sinfo.calls" ]]'

setup='marker 40; result_started'
run_case "started, no end marker, inside its window" >/dev/null
check "marker kept"       'marker_kept'
check "traced as waiting" 'traced "not running here yet -- waiting"'

## RUN_RECOVERY is `no` here, so its trace line is the proof the path is
## reached at all. See docs/explanation/sequencing.md#a-queued-job-must-not-outrank-a-drain.
setup='marker 40'
run_case "queued, and recovery still gets a look" >/dev/null
check "recovery reached"  'traced "recovery paused"'
check "traced as waiting" 'traced "not running here yet -- waiting"'
check "nothing submitted" '! submitted'

## The exception the guard keeps: our job running here means the node works.
setup='marker 40; STUB_LOCAL_JOBS=4242'
run_case "running here, so recovery is left alone" >/dev/null
check "recovery not reached" '! traced "recovery paused"'

echo "== a job that has finished =="

setup='marker 300; result_done'
run_case "result file carries an end marker" >/dev/null
check "marker cleared"     '! marker_kept'
check "traced as finished" 'traced "finished after"'

setup='marker 40; STUB_LOCAL_JOBS=4242'
run_case "running here now" >/dev/null
check "marker kept"          'marker_kept'
check "traced as running"    'traced "running here for"'
check "controller not asked" '[[ ! -f "$CASE_DIR/squeue.calls" && ! -f "$CASE_DIR/sinfo.calls" ]]'

echo "== past the grace, so the node view is read =="

## 30m grace, so 4000s is past the bound and the 40s cases above are inside it.
setup='marker 4000; STUB_SQUEUE_J="PENDING Resources"'
run_case "still queued" >/dev/null
check "marker kept"        'marker_kept'
check "traced as queued"   'traced "still queued after"'
check "nothing submitted"  '! submitted'

## Past the 30m grace, inside the 20m walltime the bound used to add to it.
setup='marker 2000; STUB_SQUEUE_J="PENDING Resources"'
run_case "past the grace, inside what the walltime used to buy" >/dev/null
check "view read, controller still not asked" '[[ ! -f "$CASE_DIR/squeue.calls" ]]'
check "traced as queued" 'traced "still queued after"'

## Held at priority 0, so it never starts. The node no longer cancels it --
## the watchdog does, fleet-wide, and this node just waits for the marker to go
## stale. tests/supervisor-test.sh is where the cancel is asserted.
## See docs/explanation/sequencing.md#jobs-the-scheduler-has-given-up-on.
setup='marker 4000; STUB_SQUEUE_J="PENDING launch failed requeued held"'
run_case "held after a failed launch" >/dev/null
check "the node cancels nothing" '[[ ! -f "$CASE_DIR/scancel.calls" ]]'
check "traced as queued"         'traced "still queued after"'
check "nothing submitted on top" '! submitted'

## The marker is cleared and the cycle carries on to resubmit, so what proves
## the old one went is the new id in its place.
setup='marker 4000'
run_case "slurm has forgotten the job" >/dev/null
check "traced as gone"        'traced "gone from the queue"'
check "resubmitted"           'submitted'
check "marker holds the new id" 'grep -q "^90001" "$logs/.in-flight"'

echo "== the node has to be able to take the job =="

## Slurm accepts a job for a drained node and holds it PENDING until somebody
## clears the drain, where it sits in everybody's squeue looking like work.
## See docs/explanation/sequencing.md#submitting-only-to-an-idle-node.
setup='STUB_STATE=drained'
run_case "drained, so nothing is submitted" >/dev/null
check "nothing submitted"    '! submitted'
check "traced with the state" 'traced "would hold probe run 1 PENDING"'
check "still eligible"        '! marker_kept'

## The trap a prefix match falls into: sinfo appends flag characters, and `idle*`
## is a node that has stopped answering.
setup='STUB_STATE="idle*"'
run_case "idle but not responding" >/dev/null
check "nothing submitted" '! submitted'

setup='STUB_STATE=allocated'
run_case "somebody else has it" >/dev/null
check "nothing submitted" '! submitted'

setup='STUB_STATE=drained; printf "SUBMIT_ONLY_WHEN_IDLE=no\n" >> "$CASE_DIR/SETTINGS"'
run_case "the gate is a site switch and can be turned off" >/dev/null
check "submitted anyway" 'submitted'

setup=''
run_case "idle, so the job goes out" >/dev/null
check "submitted" 'submitted'

setup='marker 4000; STUB_NO_VIEW=1'
run_case "there is no usable node view" >/dev/null
check "marker kept"          'marker_kept'
check "traced as unanswered" 'traced "not known whether"'
check "nothing archived"     '[[ ! -f "$logs/probe.fail1.txt" ]]'
check "nothing submitted"    '! submitted'

setup='marker 4000; result_started; STUB_NO_VIEW=1'
run_case "no view, with a partial result on disk" >/dev/null
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
setup='STUB_NO_VIEW=1'
run_case "no marker, and no usable node view" >/dev/null
check "nothing submitted" '! submitted'
check "traced"            'traced "whether a job of ours is already out"'
check "no marker written" '! marker_kept'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

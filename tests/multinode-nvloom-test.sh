#!/bin/bash
# Manual rack launch guards and advisory isolation; see docs/how-to/run-nvloom-tests.md.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree="$work/tree"
stub="$work/bin"
mkdir -p "$stub" "$tree/jobs/nvl72" "$tree/parsers/nvl72"
cp "$repo/settings.sh" "$repo/priv.sh" "$repo/slurm-snapshot.sh" "$repo/reason-map.sh" "$tree/"
cp "$repo/fanout.sh" "$repo/get-out-of-the-way.sh" "$repo/report-format.sh" "$tree/"
cp "$repo/parsers/nvl72/verdict.sh" "$tree/parsers/nvl72/"
cp "$repo/jobs/nvl72/nvloom-rack-nvlink.sbatch" "$tree/jobs/nvl72/"
printf '#!/bin/bash\necho PENDING\n' > "$tree/jobs/nvl72/probe.sbatch"
export PATH="$stub:$PATH" STUB_TREE="$tree" STUB_WORK="$work"
export LAUNCH_JOB_HOME="$tree" SETTINGS_HOME="$tree" HOSTNAME=node01
export STUB_MODE='' STUB_EXPANSION_MODE=''
mapfile -t rack_nodes < <(printf 'node%02d\n' {1..18})
nodelist=$(IFS=,; printf '%s' "${rack_nodes[*]}")

cat > "$stub/scontrol" <<'STUB'
#!/bin/bash
if [[ "$1 $2" == 'show hostnames' ]]; then
    case $STUB_EXPANSION_MODE in
        failed) exit 1 ;;
        empty) exit 0 ;;
        invalid) printf '../node01\n'; exit 0 ;;
        duplicate) printf 'node%02d\n' {1..17}; echo node01; exit 0 ;;
    esac
    case $3 in
        'node[01-18]') printf 'node%02d\n' {1..18} ;;
        'node[01-17]') printf 'node%02d\n' {1..17} ;;
        *) printf '%s\n' "${3//,/$'\n'}" ;;
    esac
    exit 0
fi
[[ $1 == listjobs ]] && { echo JOBID; exit 0; }
echo "scontrol $*" >> "$STUB_WORK/unsafe.calls"
exit 99
STUB
cat > "$stub/sbatch" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_TREE/sbatch.calls"
[[ $STUB_MODE == failed ]] && { echo 'submission refused'; exit 1; }
[[ $STUB_MODE == ambiguous ]] && exit 124
if [[ $STUB_MODE == blocked ]]; then
    touch "$STUB_TREE/entered"
    for ((i=0; i<500; i++)); do
        [[ -e "$STUB_TREE/release" ]] && break
        sleep 0.01
    done
    [[ -e "$STUB_TREE/release" ]] || exit 1
fi
echo 'Submitted batch job 90001'
STUB
cat > "$stub/sinfo" <<'STUB'
#!/bin/bash
if [[ "$*" == *'%N|%G|%c'* ]]; then
    printf 'node%02d|gpu:gb200:4|72\n' {1..18}
else
    printf 'node%02d|idle|none||\n' {1..18}
fi
STUB
cat > "$stub/squeue" <<'STUB'
#!/bin/bash
cat "$STUB_TREE/queue"
STUB
cat > "$stub/systemctl" <<'STUB'
#!/bin/bash
[[ $1 == list-unit-files ]] && { echo 'slurmd.service enabled'; exit 0; }
echo "systemctl $*" >> "$STUB_WORK/unsafe.calls"
exit 99
STUB
for command in scancel sudo ssh clush pdsh; do
    cat > "$stub/$command" <<'STUB'
#!/bin/bash
echo "${0##*/} $*" >> "$STUB_WORK/unsafe.calls"
exit 99
STUB
done
chmod 755 "$stub/"*

pass=0; fail=0
ok() { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); cat "$tree/out"; }
check() {
    local label=$1; shift
    if "$@"; then ok "$label"; else bad "$label"; fi
}
traced() { grep -qF "$1" "$tree/out"; }
no_submit() { [[ ! -s "$tree/sbatch.calls" ]]; }
one_submit() { [[ $(wc -l < "$tree/sbatch.calls") -eq 1 ]]; }

write_views() (
    source "$tree/slurm-snapshot.sh"
    SNAPSHOT_QUERIED=1
    SNAPSHOT_NODES=$(printf '%s|idle|none||\n' "${rack_nodes[@]}")
    SNAPSHOT_HW=$(printf '%s|gpu:gb200:4|72\n' "${rack_nodes[@]}")
    SNAPSHOT_QUEUE=$(cat "$tree/queue")
    snapshot_write "$tree/results" "$(date +%s)" "${rack_nodes[@]}"
)
reset_case() {
    rm -rf "$tree/results"
    rm -f "$tree/sbatch.calls" "$tree/entered" "$tree/release"
    : > "$tree/queue"
    cat > "$tree/SETTINGS" <<EOF
JOB_USER=$(id -un)
JOBS=nvl72
PARSERS=nvl72
BRINGUP_HOME=$tree
BRINGUP_DATA=$tree
BENCHMARKS=probe
BURNIN=''
CONTINUE_RUNNING_JOBS=''
RUN_BURNIN=no
RUN_JOBS=yes
RUN_RECOVERY=yes
RECOVER_SLURM_DRAINS=yes
DRAIN_AFTER_FAILED_BENCHMARK=yes
PRIV_SCONTROL=direct
MULTINODE_NVLOOM_NODES='node[01-18]'
EOF
    write_views
    printf 'unchanged\n' > "$tree/results/node01/quick-view.txt"
    printf 'ok\nPENDING\n' > "$tree/results/node01/probe.txt"
    STUB_MODE=''; STUB_EXPANSION_MODE=''; HOSTNAME=node01
}
enable() { echo RUN_MULTINODE_NVLOOM=yes >> "$tree/SETTINGS"; }
launch() {
    "$repo/actions/launch_job.sh" --verbose "$@" > "$tree/out" 2>&1
    launch_rc=$?
}
run_test() { launch --test nvloom-rack-nvlink "$@"; }

reset_case
run_test --all
check 'unset opt-in stays disabled even with --test and --all' traced 'RUN_MULTINODE_NVLOOM=no'
check 'disabled run submits nothing' no_submit

reset_case; enable
echo RUN_MULTINODE_NVLOOM=typo >> "$tree/SETTINGS"
run_test
check 'unrecognized opt-in is disabled' no_submit

reset_case; enable
launch
check 'enabling the switch never schedules a normal cycle' no_submit

reset_case; enable
cat >> "$tree/SETTINGS" <<'EOF'
BENCHMARKS='probe nvloom-rack-nvlink'
BURNIN=nvloom-rack-nvlink
RUN_BURNIN=yes
CONTINUE_RUNNING_JOBS=nvloom-rack-nvlink
EOF
printf 'FAIL\n' > "$tree/results/node01/nvloom-rack-nvlink.txt"
launch
check 'rack job is skipped in automatic benchmark lists' traced 'skip nvloom-rack-nvlink in BENCHMARKS'
check 'rack job is skipped in automatic burn-in lists' traced 'skip nvloom-rack-nvlink in BURNIN'
check 'rack job is skipped in continuous lists' traced 'skip nvloom-rack-nvlink in CONTINUE_RUNNING_JOBS'
check 'misconfigured lists cannot schedule the rack job' no_submit

reset_case; enable
launch --test nvloom-rack-nvlink --test probe
check 'mixed manual jobs are refused' test "$launch_rc" -eq 2
check 'mixed manual jobs submit nothing' no_submit

for mode in failed empty invalid duplicate; do
    reset_case; enable
    STUB_EXPANSION_MODE=$mode
    run_test
    check "$mode node expansion cannot submit" no_submit
    check "$mode node expansion reports a configuration error" test "$launch_rc" -eq 2
done

reset_case; enable
echo "MULTINODE_NVLOOM_NODES='node[01-17]'" >> "$tree/SETTINGS"
run_test
check '17-node list is rejected' traced 'exactly 18 distinct nodes, got 17'
check '17-node list submits nothing' no_submit

reset_case; enable
echo "MULTINODE_NVLOOM_NODES=''" >> "$tree/SETTINGS"
run_test
check 'empty rack selection is explained' traced 'MULTINODE_NVLOOM_NODES is empty'
check 'empty rack selection submits nothing' no_submit

reset_case; enable
HOSTNAME=outside
run_test
check 'a host outside the selected rack cannot launch it' traced 'outside is not in MULTINODE_NVLOOM_NODES'
check 'outside host submits nothing' no_submit

reset_case; enable
echo RUN_JOBS=no >> "$tree/SETTINGS"
run_test --force
check 'RUN_JOBS pause applies to explicit rack tests' traced 'RUN_JOBS=no -- no multinode'
check 'paused rack test submits nothing' no_submit

for condition in missing stale drained unknown inflight allocated queued; do
    reset_case; enable
    view="$tree/results/node18/.slurm-view"
    case $condition in
        missing) rm "$view" ;;
        stale) touch -d '20 minutes ago' "$view" ;;
        drained) sed -i 's/state\tidle/state\tdrained/' "$view" ;;
        unknown) sed -i 's/state\tidle/state\t/' "$view" ;;
        inflight) printf '123\tprobe\t1\t1\t1\n' > "$tree/results/node18/.in-flight" ;;
        allocated) sed -i '/^end/i job\t123\tRUNNING\tother\tnone\tforeign' "$view" ;;
        queued) sed -i '/^end/i ours\t123\tPENDING\tbringup-node18\tResources' "$view" ;;
    esac
    run_test
    check "$condition member blocks the entire rack submission" no_submit
done

reset_case; enable
run_test --explain
check 'preview shows the full multinode submission' traced 'WOULD SUBMIT multinode NVLoom (advisory only)'
check 'preview submits nothing' no_submit
check 'preview creates no submission state' test ! -e "$tree/results/.multinode-nvloom"

reset_case; enable
echo 'JOB_ENV="RACK_SAMPLES=7 MPI_IFACE=bond0"' >> "$tree/SETTINGS"
run_test
check 'explicit enabled invocation submits one job' one_submit
check 'submission requests the validated 18-node count' grep -qF -- '--nodes=18' "$tree/sbatch.calls"
check 'submission uses every selected node' grep -qF -- "--nodelist=$nodelist" "$tree/sbatch.calls"
check 'submission uses a separate advisory job name' grep -qF -- '--job-name=nvloom-rack-node01' "$tree/sbatch.calls"
check 'submission forwards MPI and sample overrides' grep -qF -- 'RACK_SAMPLES=7,MPI_IFACE=bond0' "$tree/sbatch.calls"
check 'submission exports the site tree for rack preflight' grep -qF -- "BRINGUP_HOME=$tree" "$tree/sbatch.calls"
check 'submission records the Slurm job ID' grep -qE $'\t90001$' "$tree/results/.multinode-nvloom/submission"
check 'advisory submission creates no timeout-drain marker' test ! -e "$tree/results/node01/.in-flight"
check 'advisory submission leaves normal quick view untouched' grep -qx unchanged "$tree/results/node01/quick-view.txt"
run_test
check 'immediate second invocation waits for a newer view' traced 'node view is not newer'
check 'immediate second invocation submits no duplicate' one_submit

touch -d '2 seconds ago' "$tree/results/.multinode-nvloom/submission"
printf '90001|nvloom-rack-node01|%s|PENDING|1|now|N/A||%s||18|Resources\n' "$(id -un)" "$nodelist" > "$tree/queue"
write_views
check 'watchdog publishes a pending rack job to every selected node' grep -qF $'ours\t90001\tPENDING\tnvloom-rack-node01' "$tree/results/node18/.slurm-view"
HOSTNAME=node18
run_test
check 'another selected node cannot duplicate a pending rack job' traced 'job 90001 is still PENDING'
check 'pending job still has only one submission' one_submit
launch
check 'normal cycles leave nodes with a pending rack job alone' traced 'manual multinode NVLoom job 90001 is PENDING'

: > "$tree/queue"
write_views
run_test
check 'a new explicit request can run after the prior job leaves the queue' test "$(wc -l < "$tree/sbatch.calls")" -eq 2

reset_case; enable
mkdir -p "$tree/results/.multinode-nvloom"
echo broken > "$tree/results/.multinode-nvloom/submission"
run_test
check 'corrupt submission state cannot authorize another job' traced 'unreadable multinode NVLoom receipt'
check 'corrupt submission state submits nothing' no_submit

for mode in failed ambiguous; do
    reset_case; enable
    STUB_MODE=$mode
    run_test
    check "$mode submission keeps a receipt" test -s "$tree/results/.multinode-nvloom/submission"
    check "$mode submission reports failure" traced 'SUBMIT FAILED multinode NVLoom'
    run_test
    check "$mode submission is not blindly retried" one_submit
done

reset_case; enable
STUB_MODE=blocked
run_test & first=$!
for ((i=0; i<100; i++)); do
    [[ -e "$tree/entered" ]] && break
    sleep 0.02
done
HOSTNAME=node18
run_test
check 'concurrent manual invocation is stopped by the shared lock' traced 'another multinode NVLoom submission holds'
touch "$tree/release"
wait "$first"
check 'concurrent manual invocations submit just one job' one_submit

reset_case; enable
cat >> "$tree/SETTINGS" <<'EOF'
RUN_ARMING=no
MAX_JOB_HOURS=1
GET_OUT_OF_THE_WAY=yes
EOF
mkdir -p "$tree/results/.multinode-nvloom"
printf 'FAIL\n' > "$tree/results/.multinode-nvloom/failed.txt"
printf '90001|nvloom-rack-node01|%s|RUNNING|1|2020-01-01T00:00:00|N/A|%s|%s||18|None\n' \
    "$(id -un)" "$nodelist" "$nodelist" > "$tree/queue"
AGENT_HOME="$tree" HOSTNAME=headnode "$repo/agent/supervisor.sh" --verbose > "$tree/out" 2>&1
check 'watchdog accepts an old running advisory job without applying timeout policy' test "$?" -eq 0
check 'advisory job remains outside automatic cancellation prefixes' bash -c \
    'source "$1/slurm-snapshot.sh"; ! snapshot_name_is_ours nvloom-rack-node01' _ "$tree"

check 'no rack path invokes node updates, recovery, cancellation or fan-out' test ! -s "$work/unsafe.calls"
[[ -s "$work/unsafe.calls" ]] && cat "$work/unsafe.calls"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

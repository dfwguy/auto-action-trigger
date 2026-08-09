#!/bin/bash
#
# Checks the drain classification and the gates in slurm-recovery.sh against
# stubbed sinfo/scontrol/squeue/systemctl/nvidia-smi on PATH, driven by STUB_*.
# The library under test is the real one, sourced; see docs/reference/jobs.md.
#
# Each case runs in a subshell, because the settings the library reads with :=
# would otherwise be fixed by whichever case ran first.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub="$work/bin"
mkdir -p "$stub" "$work/health-checks/test"

## One check, so a reason of "bios" classifies as health rather than free text.
cat > "$work/health-checks/test/10-bios.sh" <<'EOF'
#!/bin/bash
# banner: ########INFO: Check BIOS
echo bios
EOF

cat > "$stub/sinfo" <<'EOF'
#!/bin/bash
[[ "$STUB_SINFO_EMPTY" == "1" ]] && exit 0
printf '%s|%s|%s|%s\n' "$STUB_STATE" "${STUB_SETTER:-none}" "$STUB_WHEN" "$STUB_REASON"
EOF

## `show node` answers the configured counts and must stay silent otherwise:
## scontrol is quiet on a successful update, and the library reads any output
## as the failure.
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
if [[ "$1" == "show" && "$2" == "node" ]]; then
    printf 'NodeName=%s CPUTot=%s Gres=gpu:gb200:%s(S:0-71) CfgTRES=cpu=%s,gres/gpu=%s\n' \
        "$3" "${STUB_CFG_CPUS:-72}" "${STUB_CFG_GPUS:-8}" \
        "${STUB_CFG_CPUS:-72}" "${STUB_CFG_GPUS:-8}"
    exit 0
fi
[[ -n "$STUB_SCONTROL_ERROR" ]] && { printf '%s\n' "$STUB_SCONTROL_ERROR"; exit 1; }
exit 0
EOF

## Two questions, told apart by the format: `%i` is the job-assigned gate, `%e`
## is the end time the unkillable gate reads. STUB_JOB_ENDS is verbatim squeue
## output, so a case can say `N/A` as easily as a timestamp.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
for a in "$@"; do [[ "$a" == "%e" ]] && { [[ -n "$STUB_JOB_ENDS" ]] &&
    printf '%s\n' "$STUB_JOB_ENDS"; exit 0; }; done
[[ -n "$STUB_JOBS" ]] && printf '%s\n' $STUB_JOBS
exit 0
EOF

## is-active answers from a file so that restart can change the answer, which
## is what the RECOVER_RESTART_SLURMD case needs. --quiet is honoured because
## the library calls it both ways and one of them is inside a $( ).
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
quiet=""; verb=""
for a in "$@"; do
    case "$a" in
        --quiet) quiet=1 ;;
        is-system-running|is-active|restart|reset-failed)
            [[ -z "$verb" ]] && verb="$a" ;;
    esac
done
case "$verb" in
    is-system-running) printf '%s\n' "${STUB_SYSTEM_STATE:-running}"; exit 0 ;;
    is-active)
        if [[ -f "$STUB_DIR/slurmd_active" ]]; then
            [[ -z "$quiet" ]] && printf 'active\n'
            exit 0
        fi
        [[ -z "$quiet" ]] && printf '%s\n' "${STUB_SLURMD_STATE:-failed}"
        exit 3 ;;
    restart)
        printf 'restart\n' >> "$STUB_DIR/systemctl.calls"
        [[ "$STUB_RESTART_WORKS" == "1" ]] && touch "$STUB_DIR/slurmd_active"
        exit 0 ;;
    reset-failed)
        printf 'reset-failed\n' >> "$STUB_DIR/systemctl.calls"; exit 0 ;;
esac
exit 0
EOF

## -L is the GPU inventory the count gate reads; everything else this library
## asks nvidia-smi is the compute-apps query.
cat > "$stub/nvidia-smi" <<'EOF'
#!/bin/bash
if [[ "$1" == "-L" ]]; then
    [[ -n "$STUB_SMI_FAIL" ]] && exit 9
    for ((i = 0; i < ${STUB_GPUS:-8}; i++)); do
        printf 'GPU %d: NVIDIA GB200 (UUID: GPU-stub-%d)\n' "$i" "$i"
    done
    exit 0
fi
[[ -n "$STUB_GPU_PIDS" ]] && printf '%s\n' $STUB_GPU_PIDS
exit 0
EOF

## `ps -p <pid> -o args=` and `-o user=`: alive only for STUB_LIVE_PID, so a
## case decides whether the flagged process is still there and who owns it.
cat > "$stub/ps" <<'EOF'
#!/bin/bash
want=""; field=""
for ((i = 1; i <= $#; i++)); do
    case "${!i}" in
        -p)     j=$((i + 1)); want="${!j}" ;;
        args=)  field="args" ;;
        user=)  field="user" ;;
    esac
done
[[ -n "$want" && "$want" == "$STUB_LIVE_PID" ]] || exit 0
case "$field" in
    args) printf '%s\n' "${STUB_LIVE_ARGS:-sshd: cmods@notty}" ;;
    user) printf '%s\n' "${STUB_LIVE_USER:-cmods}" ;;
esac
exit 0
EOF

cat > "$stub/slurmd" <<'EOF'
#!/bin/bash
[[ "$1" == "-C" ]] && printf 'NodeName=testnode CPUs=%s Boards=1\n' "${STUB_CPUS:-72}"
exit 0
EOF

chmod 755 "$stub"/*

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

## One case: $1 name, $2 expected RECOVER_RESULT, rest VAR=value overrides.
## The per-case directory carries the assertions -- scontrol.calls exists only
## if the library issued one, and recover.log is seeded where history matters.
setup=""
run_case() {
    local name="$1" want="$2"; shift 2
    local dir="$work/case-$((pass + fail))"
    mkdir -p "$dir"

    (
        export PATH="$stub:$PATH" STUB_DIR="$dir"
        export STUB_STATE="drained" STUB_SETTER="slurm" STUB_WHEN="2026-07-28T04:12:00"
        export STUB_REASON="" STUB_JOBS="" STUB_GPU_PIDS="" STUB_SINFO_EMPTY=""
        ## Empty is "no allocation left here at all", which is the orphaned-
        ## process case and not a job still owed time.
        export STUB_JOB_ENDS=""
        export STUB_RESTART_WORKS="" STUB_SCONTROL_ERROR=""
        ## A node whose hardware is all present, so only a case that says
        ## otherwise exercises the short-count path.
        export STUB_GPUS="8" STUB_CPUS="72" STUB_CFG_GPUS="8" STUB_CFG_CPUS="72"
        export STUB_SMI_FAIL=""
        export STUB_SYSTEM_STATE="running" STUB_SLURMD_STATE="failed"
        export STUB_LIVE_PID="" STUB_LIVE_ARGS="" STUB_LIVE_USER="cmods"
        ## Off unless a case points it at the fixture below: the shipped path
        ## is a BCM one that does not exist on a test host.
        RECOVER_PREJOB_LOGS=""
        ## /proc/uptime is the one input here that cannot be stubbed, so the
        ## floor is off unless a case is testing it.
        RECOVER_MIN_UPTIME_SECS="0"
        touch "$dir/slurmd_active"

        source "$home/settings.sh"
        HEALTHCHECKS_DIR="$work/health-checks/test"
        RECOVER_ACCEPT="machine"
        RECOVER_LOG="$dir/recover.log"

        ## After the settings so a case can contradict them, before the
        ## library so its := defaults see them.
        for kv in "$@"; do
            printf -v "${kv%%=*}" '%s' "${kv#*=}"
        done
        eval "$setup"

        recover_log() { printf '%s\n' "$*" >> "$dir/trace"; }
        source "$home/slurm-recovery.sh"
        slurm_recover_node "testnode" > "$dir/out" 2>&1
        printf '%s' "$RECOVER_RESULT" > "$dir/result"
    )

    local got; got=$(cat "$dir/result" 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        ok "$name -> $got"
    else
        bad "$name -> got '$got', wanted '$want'"
        sed 's/^/       /' "$dir/trace" 2>/dev/null
    fi
    CASE_DIR="$dir"
    setup=""
}

## Matched on the update itself: the count gate also calls `scontrol show node`,
## which is not a resume.
resumed_node() { grep -q 'state=RESUME' "$CASE_DIR/scontrol.calls" 2>/dev/null; }

echo "== drains Slurm set itself =="

run_case "prolog failure, set by slurm" resumed STUB_REASON="Prolog error"
resumed_node || bad "  ... but no scontrol update was issued"

run_case "epilog failure"          resumed STUB_REASON="Epilog error"
run_case "rogue process"           resumed STUB_REASON="rogueprocess"
run_case "rogue process, spelled with a space" resumed STUB_REASON="rogue process detected"

## The pre-job check's own log, verbatim from a drained node: the drain reason
## says "rogueprocess" and nothing else, so this is the only place the process
## is named. docs/explanation/drain-recovery.md#a-rogue-process-drain-names-its-process
mkdir -p "$work/prejob"
cat > "$work/prejob/job.114250.log" <<'EOF'
HealthCheckForWlmJob healthchecks for: 114250
========= ink50-dh01-h03-16 ========
rogueprocess is FAIL, /usr/sbin/sshd (cmods)/* 503852 */
Pre-job health checks have failed
EOF

run_case "rogue process, the flagged one is gone" resumed \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/prejob"

run_case "rogue process, still logged in" not-ready \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/prejob" \
    STUB_LIVE_PID="503852" STUB_LIVE_ARGS="sshd: cmods@pts/0"
resumed_node && bad "  ... and it resumed into the same failing pre-job check"
grep -q "pid 503852" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not name the process holding the node"
grep -q "job.114250.log" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say where that came from"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and it spent an attempt on a hold"

## A pid on its own is not proof once pids have been reused.
run_case "rogue process, pid reused by something else" resumed \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/prejob" \
    STUB_LIVE_PID="503852" STUB_LIVE_ARGS="/usr/bin/python3 /opt/monitor.py"

## And the command is not proof either: `sshd` matches the sshd daemon, which
## is running on every node all the time. The user has to place it too.
run_case "rogue process, pid reused by the sshd daemon" resumed \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/prejob" \
    STUB_LIVE_PID="503852" STUB_LIVE_USER="root" \
    STUB_LIVE_ARGS="/usr/sbin/sshd -D [listener] 0 of 10-100 startups"

## Nothing prunes failed-pre-jobs/, so a log from a previous incident is still
## the newest one. It must not be read as this drain's cause.
mkdir -p "$work/prejob-stale"
cp "$work/prejob/job.114250.log" "$work/prejob-stale/"
touch -d '2026-06-11 14:56:00' "$work/prejob-stale/job.114250.log"
run_case "rogue process, log predates the drain" resumed \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/prejob-stale" \
    STUB_LIVE_PID="503852" STUB_LIVE_ARGS="sshd: cmods@pts/0"
## The rejection is right and the silence was not: four resumes on one node
## named no cause at all. docs/explanation/drain-recovery.md#when-nothing-names-the-check
grep -q "different incident" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say the log was rejected as too old"

run_case "rogue process, no pre-job logs on this node" resumed \
    STUB_REASON="rogueprocess" RECOVER_PREJOB_LOGS="$work/nonexistent" \
    STUB_LIVE_PID="503852"
grep -q "does not exist on this node" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say the directory was missing"

run_case "pre-job logs turned off" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS=""
grep -q "RECOVER_PREJOB_LOGS is empty" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say nothing reads it"

mkdir -p "$work/prejob-empty"
run_case "pre-job log directory has no logs" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-empty"
grep -q "no readable job" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say the directory was empty"

## A log that is current and readable but records no failure still leaves the
## drain unexplained, and that is a fifth way to say nothing.
mkdir -p "$work/prejob-clean"
cat > "$work/prejob-clean/job.114251.log" <<'EOF'
HealthCheckForWlmJob healthchecks for: 114251
========= ink50-dh01-h03-16 ========
Pre-job health checks have failed
EOF

run_case "pre-job log names no failed check" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-clean"
grep -q "names no failed check" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say the log explained nothing"

## The format on a live fleet: several commands, then ONE pid list for all of
## them. An earlier pattern matched only the single-pid case and so never fired
## on any of these. docs/explanation/drain-recovery.md#a-rogue-process-drain-names-its-process
mkdir -p "$work/prejob-multi"
cat > "$work/prejob-multi/job.114250.log" <<'EOF'
HealthCheckForWlmJob healthchecks for: 114250
========= ink50-dh01-h01-11 ========
rogueprocess is FAIL, /usr/bin/bash (nvis-ib), /usr/sbin/sshd (nvis-ib)/* 14533, 14535 */
Pre-job health checks have failed
EOF

run_case "several processes, the second pid is still there" not-ready \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-multi" \
    STUB_LIVE_PID="14535" STUB_LIVE_ARGS="sshd: nvis-ib [priv]" STUB_LIVE_USER="root"
resumed_node && bad "  ... and it resumed into the same failing pre-job check"
grep -q "pid 14535" "$CASE_DIR/trace" || bad "  ... and the trace did not name it"

run_case "several processes, the first pid is still there" not-ready \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-multi" \
    STUB_LIVE_PID="14533" STUB_LIVE_ARGS="/usr/bin/bash -l" STUB_LIVE_USER="nvis-ib"

run_case "several processes, all of them gone" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-multi"

## Every other check puts its own count between the same /* */ markers. Reading
## 4790 as a pid would hold nodes on whatever process had inherited the number.
mkdir -p "$work/prejob-dmesg"
cat > "$work/prejob-dmesg/job.114250.log" <<'EOF'
HealthCheckForWlmJob healthchecks for: 114250
========= ink50-dh01-h20-35 ========
dmesg is FAIL, /* 4790 */ matches for regex: hardware error
Pre-job health checks have failed
EOF

run_case "a match count is not a pid" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob-dmesg" \
    STUB_LIVE_PID="4790" STUB_LIVE_ARGS="/usr/sbin/sshd -D" STUB_LIVE_USER="root"

## ... but what failed is still written down, or a node flapping on a hardware
## fault does it behind a drain reason that only ever says `Prolog error`.
grep -q "failed on \[dmesg\]" "$CASE_DIR/trace" ||
    bad "  ... and nothing named the check that actually drained the node"
## And it has to outlive trigger.log, which is trimmed to 2000 lines inside a
## day. recover.log is what an operator reads three drains later.
awk -F'\t' '$7 == "dmesg" { found = 1 } END { exit !found }' "$CASE_DIR/recover.log" ||
    bad "  ... and recover.log kept the resume without the check that caused it"
awk -F'\t' '$1 ~ /^[0-9]+$/ && $6 == "Prolog error" { found = 1 } END { exit !found }' \
    "$CASE_DIR/recover.log" ||
    bad "  ... and the seventh field displaced one the readers key on"

## What the drain reason actually says on a node the pre-job check failed: the
## prolog is what runs it, and only its log knows a rogue process was why.
run_case "prolog error, the rogue process is still there" not-ready \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob" \
    STUB_LIVE_PID="503852" STUB_LIVE_ARGS="sshd: cmods@pts/0"
resumed_node && bad "  ... and it resumed into the same failing pre-job check"

run_case "prolog error, nothing left running" resumed \
    STUB_REASON="Prolog error" RECOVER_PREJOB_LOGS="$work/prejob"
run_case "failed batch launch"     resumed STUB_REASON="batch job complete failure"
run_case "kill task failed"        resumed STUB_REASON="Kill task failed"
run_case "unexpected reboot"       resumed STUB_REASON="node unexpectedly rebooted"
run_case "down, not drained"       resumed STUB_REASON="Prolog error" STUB_STATE="down"

## Registration disagreements, not node faults.
## See docs/explanation/drain-recovery.md.
run_case "duplicate jobid"         resumed STUB_REASON="Duplicate jobid"

echo "== rebooted out from under Slurm =="

## Nobody reboots these cleanly. The node comes back with the drain still on it
## and, often, a slurmd that tripped systemd's start limit on the way up.
## docs/explanation/drain-recovery.md#restarting-slurmd
run_case "node was stopped"  resumed STUB_REASON="Node was stopped by root"
run_case "not responding"    resumed STUB_REASON="Not responding"

setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "rebooted, slurmd failed to start" resumed \
    STUB_REASON="Node was stopped by root" STUB_RESTART_WORKS="1"
grep -q '^reset-failed' "$CASE_DIR/systemctl.calls" 2>/dev/null ||
    bad "  ... but the start limit was never cleared, so restart would be refused"
grep -q '^restart' "$CASE_DIR/systemctl.calls" 2>/dev/null ||
    bad "  ... but slurmd was never restarted"
grep -q "slurmd is 'failed'" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not say what state slurmd was in"

echo "== nothing is judged mid-boot =="

## Race conditions on race conditions: a node still coming up reports counts
## that are still changing. docs/explanation/drain-recovery.md#nothing-is-judged-mid-boot
run_case "still inside the uptime floor" not-ready \
    STUB_REASON="node unexpectedly rebooted" RECOVER_MIN_UPTIME_SECS="999999999"
resumed_node && bad "  ... and it resumed a node that had just booted"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and it spent an attempt on a hold"

run_case "systemd still starting" not-ready \
    STUB_REASON="node unexpectedly rebooted" STUB_SYSTEM_STATE="starting"
resumed_node && bad "  ... and it resumed a node whose boot had not finished"

run_case "systemd degraded is still up" resumed \
    STUB_REASON="node unexpectedly rebooted" STUB_SYSTEM_STATE="degraded"

echo "== count drains, checked against the hardware =="

## The race this exists for: slurmd counted before the driver finished, so the
## hardware is present and slurmctld is holding a number that no longer is.
## docs/explanation/drain-recovery.md#a-count-drain-is-checked-against-the-hardware
gres_short="gres/gpu count reported by slurmd (7) lower than configured (8)"
cpu_short="Low socket*core*thread count, Low CPUs"

run_case "gres count, all GPUs back" resumed STUB_REASON="$gres_short"
[[ -s "$CASE_DIR/systemctl.calls" ]] ||
    bad "  ... but slurmd was never restarted, so slurmctld kept the cached count"

run_case "low CPU count, all CPUs back" resumed STUB_REASON="$cpu_short"
[[ -s "$CASE_DIR/systemctl.calls" ]] ||
    bad "  ... but slurmd was never restarted, so slurmctld kept the cached count"

## A GPU that really is gone. The node says so itself, so this must hold rather
## than resume -- and must not spend an attempt doing it.
run_case "gres count, a GPU really is missing" not-ready \
    STUB_REASON="$gres_short" STUB_GPUS="7"
resumed_node && bad "  ... and it resumed a node that is short a GPU"
[[ -s "$CASE_DIR/systemctl.calls" ]] &&
    bad "  ... and it restarted slurmd over hardware that is genuinely absent"
grep -q "only 7 of 8 GPUs" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not name the counts"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and it spent an attempt on a hold"

run_case "low CPU count, CPUs really are missing" not-ready \
    STUB_REASON="$cpu_short" STUB_CPUS="36"
resumed_node && bad "  ... and it resumed a node that is short CPUs"
grep -q "only 36 of 72 CPUs" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not name the counts"

## The configured count comes from Slurm's own text when it is there, so a
## node whose slurm.conf disagrees with scontrol is still judged on the reason.
run_case "gres reason wins over scontrol" not-ready \
    STUB_REASON="$gres_short" STUB_GPUS="7" STUB_CFG_GPUS="4"

## A reason carrying no numbers falls back to `Gres=` from scontrol, where the
## `(S:0-71)` topology suffix has a colon of its own and the count does not.
run_case "gres count, configured count from scontrol" not-ready \
    STUB_REASON="gres/gpu count too low" STUB_GPUS="3" STUB_CFG_GPUS="8"
grep -q "only 3 of 8 GPUs" "$CASE_DIR/trace" ||
    bad "  ... and the configured count was misparsed out of scontrol's Gres="

## The other spelling, reported first: `(0 < 4)`. Asserted on the message,
## because a parse that missed would fall back to scontrol's 8 and still hold.
run_case "gres count, the reported-first spelling" not-ready \
    STUB_REASON="gres/gpu count reported lower than configured (0 < 4)" \
    STUB_GPUS="0"
grep -q "only 0 of 4 GPUs" "$CASE_DIR/trace" ||
    bad "  ... and the configured count did not come from the reason"

run_case "gres count reported as 0, GPUs all back" resumed \
    STUB_REASON="gres/gpu count reported lower than configured (0 < 4)"
grep -q '^restart' "$CASE_DIR/systemctl.calls" 2>/dev/null ||
    bad "  ... but slurmd was never restarted, so slurmctld kept the 0"

run_case "re-registration switched off" resumed \
    STUB_REASON="$gres_short" RECOVER_REREGISTER="no"
[[ -s "$CASE_DIR/systemctl.calls" ]] &&
    bad "  ... but slurmd was restarted with RECOVER_REREGISTER=no"
grep -q "RECOVER_REREGISTER=no" "$CASE_DIR/trace" ||
    bad "  ... and nothing said why the node is likely to drain again"

run_case "count drain, dry run" resumed \
    STUB_REASON="$gres_short" RECOVER_DRY_RUN="1"
[[ -s "$CASE_DIR/systemctl.calls" ]] && bad "  ... but --explain restarted slurmd"
grep -q "WOULD RESTART" "$CASE_DIR/trace" ||
    bad "  ... and --explain did not say it would"

## Zero is a count and a real one, but nvidia-smi *failing* is the node saying
## the thing the drain complains about -- not an absence of evidence.
run_case "nvidia-smi will not answer" not-ready \
    STUB_REASON="$gres_short" STUB_SMI_FAIL="1"
resumed_node && bad "  ... and it resumed a node whose GPU stack is not up"

## No count to read is not a count that is wrong: the behaviour before any of
## this existed, rather than a node held on a number we could not get.
run_case "configured count unreadable, resumed as before" resumed \
    STUB_REASON="$cpu_short" STUB_CFG_CPUS="none" STUB_CPUS="36"

echo "== no reason at all =="

run_case "empty reason, opted in"  resumed     STUB_REASON="none"
run_case "empty reason, opted out" class       STUB_REASON="none" RECOVER_EMPTY_REASON="no"
run_case "literally empty reason"  resumed     STUB_REASON=""

echo "== reasons Slurm appends to =="

## Slurm appends " : Not responding" to the reason already on the node and
## signs the result itself, so an operator's drain arrives set by slurm. What
## was there first is what decides. docs/explanation/drain-recovery.md#reasons-slurm-appends-to
run_case "operator reason, then it stopped responding" class \
    STUB_REASON="BF3 TEST BY AIC : Not responding"
resumed_node && bad "  ... and it resumed a node somebody had taken for testing"

run_case "operator reason with a ticket, then not responding" class \
    STUB_REASON="AIC UPDATE PXE BIOS : Not responding"
resumed_node && bad "  ... and it resumed a node mid-BIOS-update"

run_case "machine reason, then it stopped responding" resumed \
    STUB_REASON="Prolog error : Not responding"

run_case "not responding on its own" resumed STUB_REASON="Not responding"

echo "== drains we must not clear =="

## Hardware tickets, whoever files them. `nvis` and `executor` are not in
## RECOVER_SETTERS; `root` is, so HW231 has to fail on its text alone.
run_case "hardware ticket, set by a named account" class \
    STUB_REASON="HW227" STUB_SETTER="nvis"
resumed_node && bad "  ... and it resumed a node with an open hardware ticket"

run_case "hardware ticket, set by executor" class \
    STUB_REASON="HW231" STUB_SETTER="executor"

run_case "hardware ticket, set by root" class \
    STUB_REASON="HW233" STUB_SETTER="root"
resumed_node && bad "  ... and root's ticket was not protected by its text"

run_case "hardware ticket with prose, set by root" class \
    STUB_REASON="HW221 - node installer stuck, needs reset" STUB_SETTER="root"

run_case "operator prose" class \
    STUB_REASON="bad NVLink, do not use" STUB_SETTER="breese"
resumed_node && bad "  ... and it resumed an operator drain"

run_case "operator prose, no setter recorded" class \
    STUB_REASON="waiting on RMA"

## The setter veto: the only discriminator left when the text looks machine-
## generated. See docs/explanation/drain-recovery.md#how-an-operators-drain-is-protected.
run_case "prolog text typed by a named admin" class \
    STUB_REASON="Prolog error" STUB_SETTER="breese"
resumed_node && bad "  ... and it resumed an operator drain"

run_case "our own benchmark drain" class \
    STUB_REASON="allreduce FAIL: bandwidth below floor (auto-retry)" \
    RECOVER_ACCEPT="machine health"

run_case "health-check drain, sequencer caller" class \
    STUB_REASON="bios"

run_case "health-check drain, health caller" resumed \
    STUB_REASON="bios" RECOVER_ACCEPT="machine health"

echo "== states that are somebody's arrangement =="

run_case "maintenance"  not-drained STUB_STATE="maint"  STUB_REASON="Prolog error"
run_case "reserved"     not-drained STUB_STATE="reserved" STUB_REASON="Prolog error"
run_case "idle"         not-drained STUB_STATE="idle"
run_case "allocated"    not-drained STUB_STATE="allocated"

echo "== readiness =="

run_case "GPUs still busy" not-ready STUB_REASON="rogueprocess" STUB_GPU_PIDS="41233 41240"
grep -q "pids 41233 41240" "$CASE_DIR/trace" ||
    bad "  ... and the trace did not name the processes holding the node"

run_case "a job is still assigned" not-ready STUB_REASON="Prolog error" STUB_JOBS="1234"

setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "slurmd down, restart switched off" not-ready \
    STUB_REASON="Prolog error" RECOVER_RESTART_SLURMD="no"

setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "slurmd down, restart works" resumed \
    STUB_REASON="Prolog error" STUB_RESTART_WORKS="1"
grep -q '^restart' "$CASE_DIR/systemctl.calls" 2>/dev/null ||
    bad "  ... but slurmd was never restarted"

## RECOVER_SLURMD_WAIT=0 so the poll gives up on its first pass rather than
## sleeping through the shipped 30s.
setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "slurmd down, restart does not fix it" not-ready \
    STUB_REASON="Prolog error" RECOVER_SLURMD_WAIT="0"

run_case "scontrol refuses the update" not-ready \
    STUB_REASON="Prolog error" STUB_SCONTROL_ERROR="Invalid user id"

echo "== rate limiting =="

## Three inside the window is the shipped cap; the fourth must leave the drain
## exactly as Slurm set it, never re-drained under our own marker.
## See docs/explanation/drain-recovery.md#why-a-resume-is-not-enough-on-its-own.
setup='now=$(date +%s); for i in 1 2 3; do
           printf "%s\tseeded\tmachine\tdrained\tslurm\tProlog error\n" "$((now - i * 600))" >> "$RECOVER_LOG"
       done'
run_case "at the cap" rate-limited STUB_REASON="Prolog error"
resumed_node && bad "  ... and it resumed anyway"
grep -q "state=DRAIN" "$CASE_DIR/scontrol.calls" 2>/dev/null &&
    bad "  ... and it re-drained the node under our own marker"

setup='now=$(date +%s); for i in 1 2; do
           printf "%s\tseeded\tmachine\tdrained\tslurm\tProlog error\n" "$((now - i * 600))" >> "$RECOVER_LOG"
       done'
run_case "one below the cap" resumed STUB_REASON="Prolog error"

## Same three recoveries, two days ago: the window has moved past them.
setup='now=$(date +%s); for i in 1 2 3; do
           printf "%s\tseeded\tmachine\tdrained\tslurm\tProlog error\n" "$((now - 172800 - i * 600))" >> "$RECOVER_LOG"
       done'
run_case "cap, but outside the window" resumed STUB_REASON="Prolog error"

run_case "a recovery is recorded" resumed STUB_REASON="Prolog error"
[[ "$(grep -c . "$CASE_DIR/recover.log" 2>/dev/null)" == "1" ]] ||
    bad "  ... but nothing was written to recover.log"

echo "== a step that outlives its own kill =="

downed_node() { grep -q 'state=DOWN' "$CASE_DIR/scontrol.calls" 2>/dev/null; }

## Shipped default. The switch gates the action only -- a site that never lets
## this tree take a node out of service still has to be told the node is wedged,
## or the held line repeats forever saying nothing new.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, but the switch is off" not-ready \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662"
downed_node && bad "  ... and it marked the node DOWN with the switch off"
grep -q "outlived its own kill" "$CASE_DIR/trace" ||
    bad "  ... and the held line did not name what it had found"
grep -q "clear-an-unkillable-step" "$CASE_DIR/trace" ||
    bad "  ... and it did not say where to read what to do about it"

run_case "unkillable, first sighting" not-ready \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662"
downed_node && bad "  ... and it marked DOWN before the clock had run"
grep -q "unchanged for 0s" "$CASE_DIR/trace" ||
    bad "  ... and the held line did not say the clock was running"

setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, past the threshold" downed \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662"
downed_node || bad "  ... but no scontrol update was issued"
resumed_node && bad "  ... and it resumed the node as well"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and it spent a resume attempt on it"

## The reason written above is the whole mechanism: classified back, it has to
## come out `operator`, or the next cycle recovers the node it just condemned.
down_reason=$(sed -n 's/.*state=DOWN reason=//p' "$CASE_DIR/scontrol.calls" | head -1)
[[ -n "$down_reason" ]] || bad "  ... and no reason was recorded to classify"
(
    source "$home/settings.sh"
    source "$home/slurm-recovery.sh"
    [[ "$(recover_classify "$down_reason" "root")" == "operator" ]]
) || bad "  ... and the reason it wrote classifies as '$(
    source "$home/settings.sh"; source "$home/slurm-recovery.sh"
    recover_classify "$down_reason" "root")', so recovery would clear it"

## Slurm appends this to whatever reason a node already had; the base of it
## still has to classify as operator.
(
    source "$home/settings.sh"
    source "$home/slurm-recovery.sh"
    [[ "$(recover_classify "$(recover_base_reason "$down_reason : Not responding")" "slurm")" == "operator" ]]
) || bad "  ... and it stops being an operator reason once Slurm appends to it"

## Different pids are a different incident, however old the stamp is.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "111 222" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, but the pid set changed" not-ready \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662"
downed_node && bad "  ... and it marked DOWN on a restarted clock"

## Every other drain reason keeps the GPUs busy too. Only the one that means
## Slurm has already failed to kill the step may take a node out of service.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "GPUs busy under some other drain" not-ready \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Prolog error" STUB_GPU_PIDS="1847634 1847662"
downed_node && bad "  ... and it marked DOWN a node Slurm never failed to kill"

## Slurm's own end time is the second proof, and an unlimited job has none:
## there is no limit to have exceeded, so nothing here may take the node out of
## service. Same for an end time this cannot read.
for end in "N/A" "UNLIMITED" "Unknown" "not-a-timestamp"; do
    setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
               > "$STUB_DIR/unkillable.stamp"'
    run_case "unkillable, job end time '$end'" not-ready \
        RECOVER_DOWN_UNKILLABLE="yes" \
        STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
        STUB_GPU_PIDS="1847634 1847662" STUB_JOB_ENDS="$end"
    downed_node && bad "  ... and it marked DOWN a node whose job may still be owed time"
done
grep -q "no time limit" "$CASE_DIR/trace" ||
    grep -q "cannot read" "$CASE_DIR/trace" ||
    bad "  ... and the held line did not say why it stopped short"

## Past its limit by an hour, and still on the GPUs: both proofs agree.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, job an hour past its limit" downed \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662" \
    STUB_JOB_ENDS="$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S')"

## Inside its limit is a job someone is legitimately still running, whatever
## an earlier step's kill did to the node.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, job still inside its limit" not-ready \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662" \
    STUB_JOB_ENDS="$(date -d '2 hours' '+%Y-%m-%dT%H:%M:%S')"
downed_node && bad "  ... and it marked DOWN a job that was still inside its limit"

## One wedged job past its limit does not license downing the node while a
## second is still owed time.
setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, one job past its limit and one not" not-ready \
    RECOVER_DOWN_UNKILLABLE="yes" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662" \
    STUB_JOB_ENDS="$(date -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S')
$(date -d '2 hours' '+%Y-%m-%dT%H:%M:%S')"
downed_node && bad "  ... and it released an allocation that was still owed time"

setup='printf "%s\t%s\n" "$(( $(date +%s) - 7200 ))" "1847634 1847662" \
           > "$STUB_DIR/unkillable.stamp"'
run_case "unkillable, dry run" downed \
    RECOVER_DOWN_UNKILLABLE="yes" RECOVER_DRY_RUN="1" \
    STUB_REASON="Kill task failed (JobId=132603 StepId=2)" \
    STUB_GPU_PIDS="1847634 1847662"
downed_node && bad "  ... but --explain issued a scontrol update"
grep -q "WOULD MARK DOWN" "$CASE_DIR/trace" ||
    bad "  ... and --explain did not say what it would have done"

echo "== switches and edges =="

run_case "recovery switched off"  disabled     RECOVER_SLURM_DRAINS="no"
run_case "node not known to slurm" unknown-node STUB_SINFO_EMPTY="1"

run_case "dry run" resumed STUB_REASON="Prolog error" RECOVER_DRY_RUN="1"
resumed_node && bad "  ... but --explain issued a scontrol update"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and --explain recorded an attempt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

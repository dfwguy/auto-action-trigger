#!/bin/bash
#
# Checks the drain classification and the gates in slurm-recovery.sh against
# stubbed sinfo/scontrol/squeue/systemctl/nvidia-smi on PATH, driven by STUB_*.
# The library under test is the real one, sourced; see docs/benchmarks.md.
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
    printf 'NodeName=%s CPUTot=%s Gres=gpu:%s CfgTRES=cpu=%s,gres/gpu=%s\n' \
        "$3" "${STUB_CFG_CPUS:-72}" "${STUB_CFG_GPUS:-8}" \
        "${STUB_CFG_CPUS:-72}" "${STUB_CFG_GPUS:-8}"
    exit 0
fi
[[ -n "$STUB_SCONTROL_ERROR" ]] && { printf '%s\n' "$STUB_SCONTROL_ERROR"; exit 1; }
exit 0
EOF

cat > "$stub/squeue" <<'EOF'
#!/bin/bash
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
    for ((i = 0; i < ${STUB_GPUS:-8}; i++)); do
        printf 'GPU %d: NVIDIA GB200 (UUID: GPU-stub-%d)\n' "$i" "$i"
    done
    exit 0
fi
[[ -n "$STUB_GPU_PIDS" ]] && printf '%s\n' $STUB_GPU_PIDS
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
        export STUB_RESTART_WORKS="" STUB_SCONTROL_ERROR=""
        ## A node whose hardware is all present, so only a case that says
        ## otherwise exercises the short-count path.
        export STUB_GPUS="8" STUB_CPUS="72" STUB_CFG_GPUS="8" STUB_CFG_CPUS="72"
        export STUB_SYSTEM_STATE="running" STUB_SLURMD_STATE="failed"
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
run_case "failed batch launch"     resumed STUB_REASON="batch job complete failure"
run_case "kill task failed"        resumed STUB_REASON="Kill task failed"
run_case "unexpected reboot"       resumed STUB_REASON="node unexpectedly rebooted"
run_case "down, not drained"       resumed STUB_REASON="Prolog error" STUB_STATE="down"

## Registration disagreements, not node faults.
## See docs/settings.md#recovering-drains-slurm-set-itself.
run_case "duplicate jobid"         resumed STUB_REASON="Duplicate jobid"

echo "== rebooted out from under Slurm =="

## Nobody reboots these cleanly. The node comes back with the drain still on it
## and, often, a slurmd that tripped systemd's start limit on the way up.
## docs/settings.md#restarting-slurmd
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
## that are still changing. docs/settings.md#nothing-is-judged-mid-boot
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
## docs/settings.md#a-count-drain-is-checked-against-the-hardware
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

## No count to read is not a count that is wrong: the behaviour before any of
## this existed, rather than a node held on a number we could not get.
run_case "count unreadable, resumed as before" resumed \
    STUB_REASON="$gres_short" STUB_GPUS="0"

echo "== no reason at all =="

run_case "empty reason, opted in"  resumed     STUB_REASON="none"
run_case "empty reason, opted out" class       STUB_REASON="none" RECOVER_EMPTY_REASON="no"
run_case "literally empty reason"  resumed     STUB_REASON=""

echo "== drains we must not clear =="

run_case "operator prose" class \
    STUB_REASON="bad NVLink, do not use" STUB_SETTER="breese"
resumed_node && bad "  ... and it resumed an operator drain"

run_case "operator prose, no setter recorded" class \
    STUB_REASON="waiting on RMA"

## The setter veto: the only discriminator left when the text looks machine-
## generated. See docs/settings.md#how-an-operators-drain-is-protected.
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
## See docs/settings.md#why-a-resume-is-not-enough-on-its-own.
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

echo "== switches and edges =="

run_case "recovery switched off"  disabled     RECOVER_SLURM_DRAINS="no"
run_case "node not known to slurm" unknown-node STUB_SINFO_EMPTY="1"

run_case "dry run" resumed STUB_REASON="Prolog error" RECOVER_DRY_RUN="1"
resumed_node && bad "  ... but --explain issued a scontrol update"
[[ -f "$CASE_DIR/recover.log" ]] && bad "  ... and --explain recorded an attempt"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

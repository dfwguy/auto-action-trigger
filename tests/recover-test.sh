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

cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scontrol.calls"
[[ -n "$STUB_SCONTROL_ERROR" ]] && { printf '%s\n' "$STUB_SCONTROL_ERROR"; exit 1; }
exit 0
EOF

cat > "$stub/squeue" <<'EOF'
#!/bin/bash
[[ -n "$STUB_JOBS" ]] && printf '%s\n' $STUB_JOBS
exit 0
EOF

## is-active answers from a file so that restart can change the answer, which
## is what the RECOVER_RESTART_SLURMD case needs.
cat > "$stub/systemctl" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        is-active) [[ -f "$STUB_DIR/slurmd_active" ]] && exit 0 || exit 3 ;;
        restart)   printf 'restart\n' >> "$STUB_DIR/systemctl.calls"
                   [[ "$STUB_RESTART_WORKS" == "1" ]] && touch "$STUB_DIR/slurmd_active"
                   exit 0 ;;
    esac
done
exit 0
EOF

cat > "$stub/nvidia-smi" <<'EOF'
#!/bin/bash
[[ -n "$STUB_GPU_PIDS" ]] && printf '%s\n' $STUB_GPU_PIDS
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

resumed_node() { [[ -s "$CASE_DIR/scontrol.calls" ]]; }

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
run_case "slurmd down, restart not allowed" not-ready STUB_REASON="Prolog error"

setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "slurmd down, restart allowed and works" resumed \
    STUB_REASON="Prolog error" RECOVER_RESTART_SLURMD="yes" STUB_RESTART_WORKS="1"
[[ -s "$CASE_DIR/systemctl.calls" ]] || bad "  ... but slurmd was never restarted"

setup='rm -f "$STUB_DIR/slurmd_active"'
run_case "slurmd down, restart allowed and fails" not-ready \
    STUB_REASON="Prolog error" RECOVER_RESTART_SLURMD="yes"

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

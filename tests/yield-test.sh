#!/bin/bash
#
# Checks the gates in get-out-of-the-way.sh against stubbed squeue/scancel/
# scontrol on PATH, driven by STUB_*. The library under test is the real one,
# sourced; see docs/explanation/sequencing.md#getting-out-of-the-way.
#
# The assertion that matters most is the negative one: every case that must not
# cancel checks scancel.calls, not just the result string.
#
# Each case runs in a subshell, because the settings the library reads with :=
# would otherwise be fixed by whichever case ran first.

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub="$work/bin"
mkdir -p "$stub"

## Two shapes, told apart the way the library asks them: the pending queue and
## one job by id. Both calls are recorded -- a case that must not ask is as much
## of an assertion as one that must.
cat > "$stub/squeue" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/squeue.calls"
case "$*" in
    *"-t PENDING"*)
        if [[ -n "$STUB_SQUEUE_FAIL" ]]; then
            printf 'slurm_load_jobs error: Unable to contact slurm controller\n'
            exit 1
        fi
        [[ -n "$STUB_PENDING" ]] && printf '%s\n' "$STUB_PENDING"
        exit 0 ;;
    *-j*)
        [[ -n "$STUB_JOB" ]] && printf '%s\n' "$STUB_JOB"
        exit 0 ;;
esac
exit 0
EOF

## `show hostnames` expands prefix[11-18,28-37] as Slurm's does -- commas inside
## the brackets and all, which is the form the real queue hands back. A case can
## then prove the node lists are expanded rather than matched as text.
cat > "$stub/scontrol" <<'EOF'
#!/bin/bash
[[ "$1" == "show" && "$2" == "hostnames" ]] || exit 0
expand() {
    if [[ "$1" =~ ^(.*)\[(.*)\]$ ]]; then
        pre="${BASH_REMATCH[1]}"
        IFS=',' read -r -a ranges <<< "${BASH_REMATCH[2]}"
        for r in "${ranges[@]}"; do
            if [[ "$r" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
                for ((i = 10#$lo; i <= 10#$hi; i++)); do
                    printf '%s%0*d\n' "$pre" "${#lo}" "$i"
                done
            else
                printf '%s%s\n' "$pre" "$r"
            fi
        done
    else
        printf '%s\n' "$1"
    fi
}
## Split on commas outside brackets only, then expand each piece.
printf '%s' "$3" | awk 'BEGIN{RS="\n"} {n=0; s=""; for (i=1; i<=length($0); i++) {
    c=substr($0,i,1)
    if (c=="[") n=1; else if (c=="]") n=0
    if (c=="," && n==0) { print s; s="" } else s = s c
} if (s != "") print s}' |
while IFS= read -r item; do expand "$item"; done
exit 0
EOF

## Refusing on stdout while exiting 0 is what the real scancel does, and the
## library reads the output rather than the status because of it.
cat > "$stub/scancel" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/scancel.calls"
[[ -n "$STUB_SCANCEL_OUT" ]] && printf '%s\n' "$STUB_SCANCEL_OUT"
exit 0
EOF

## The cancel drops to YIELD_USER when it is root, and CI runs its jobs as root
## while a developer does not -- so without this the suite tests a different
## branch depending on who ran it, and was green locally and red in CI.
## See docs/explanation/sequencing.md#the-prefix-is-the-gate.
cat > "$stub/su" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/su.calls"
[[ -n "$STUB_SU_OUT" ]] && { printf '%s\n' "$STUB_SU_OUT"; exit 1; }
## What a login shell is for here is putting the client tools on PATH, which
## the stub PATH has already done: run the scancel, not the module lines.
cmd=""
for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == "-c" ]] && { j=$((i + 1)); cmd="${!j}"; }
done
exec bash -c "${cmd##*;}"
EOF

chmod 755 "$stub"/*

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
## Counted as neither: a case this uid cannot reach has not passed.
skip() { printf '  skip %s\n' "$*"; }

NODE=ink50-dh01-i01-13
OURS="bringup-$NODE burnin-$NODE"
## What the controller says about the job in the marker unless a case differs:
## ours, our user's, running here.
JOB_OK="4242|cmods|bringup-$NODE|RUNNING|$NODE|"
## A foreign job that has been pending for an hour on this node by name, at a
## priority that is not 0 -- 0 is held, and held is not waiting.
WAITER="9001|alice|train-70b|$NODE||3600|4294901759|"

## One case: $1 name, $2 expected YIELD_RESULT, rest VAR=value overrides.
run_case() {
    local name="$1" want="$2"; shift 2
    local dir="$work/case-$((pass + fail))"
    mkdir -p "$dir"

    (
        export PATH="$stub:$PATH" STUB_DIR="$dir"
        export STUB_PENDING="$WAITER" STUB_JOB="$JOB_OK"
        export STUB_SQUEUE_FAIL="" STUB_SCANCEL_OUT="" STUB_SU_OUT=""

        source "$home/settings.sh"
        GET_OUT_OF_THE_WAY=yes
        YIELD_OURS="$OURS"
        YIELD_USER=cmods
        YIELD_STAMP="$dir/.yield-check"
        YIELD_DRY_RUN=0

        ## After the settings so a case can contradict them, before the library
        ## so its := defaults see them.
        for kv in "$@"; do
            printf -v "${kv%%=*}" '%s' "${kv#*=}"
        done

        ## A stamp from a moment ago, for the case that tests the poll interval.
        [[ -n "$setup_stamp" ]] && : > "$YIELD_STAMP"

        yield_log() { printf '%s\n' "$*" >> "$dir/trace"; }
        source "$home/get-out-of-the-way.sh"
        yield_to_waiter "${STUB_WANT:-4242}" "$NODE" > "$dir/out" 2>&1
        printf '%s' "$YIELD_RESULT" > "$dir/result"
    )

    local got; got=$(cat "$dir/result" 2>/dev/null)
    if [[ "$got" == "$want" ]]; then
        ok "$name -> $got"
    else
        bad "$name -> got '$got', wanted '$want'"
        sed 's/^/       /' "$dir/trace" 2>/dev/null
    fi
    CASE_DIR="$dir"
}

cancelled()      { grep -q '4242' "$CASE_DIR/scancel.calls" 2>/dev/null; }
nothing_killed() { [[ ! -f "$CASE_DIR/scancel.calls" ]]; }

echo "== a job is waiting for the node =="

run_case "waiter names the node" yielded
cancelled || bad "  ... but scancel was never called"

## Compressed, and the node is inside the range: proof the list is expanded.
run_case "waiter is scheduled onto the node" yielded \
    STUB_PENDING="9001|alice|train-70b||ink50-dh01-i01-[11-18]|3600|4294901759|"
cancelled || bad "  ... but scancel was never called"

## Straight off a head node, and the case this feature exists for: the waiter
## runs as JOB_USER too, so only the job name tells it from one of ours, and
## SchedNodes reads `(null)` rather than empty.
run_case "the real queue's waiter" yielded \
    STUB_PENDING="130938|cmods|microbenchmark_nccl_nccl_fp8|ink50-dh01-i01-[11-18,28-37]|(null)|1698|4294901759|
130939|cmods|bringup-ink50-dh01-i05-31|ink50-dh01-i05-31|(null)|1677|4294901758|"
cancelled || bad "  ... but scancel was never called"

run_case "only jobs of ours are queued" no-waiter \
    STUB_PENDING="130939|cmods|bringup-$NODE|$NODE|(null)|1677|4294901759|
130937|cmods|burnin-$NODE|$NODE|(null)|1710|4294901758|"
nothing_killed || bad "  ... but something was cancelled"

## squeue -O pads to the field width; every field arrives with it attached.
run_case "padded squeue output" yielded \
    STUB_PENDING="9001      |alice   |train-70b   |$NODE   |    |3600  |4294901759  |" \
    STUB_JOB="4242    |cmods   |bringup-$NODE  |RUNNING |$NODE  |"
cancelled || bad "  ... but scancel was never called"

echo "== nobody is waiting =="

run_case "empty queue"            no-waiter STUB_PENDING=""
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter is a job of ours" no-waiter STUB_PENDING="9001|cmods|bringup-othernode|$NODE||3600|4294901759|"
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter wants other nodes" no-waiter \
    STUB_PENDING="9001|alice|train-70b|ink50-dh01-i01-[11-12]||3600|4294901759|"
nothing_killed || bad "  ... but something was cancelled"

## Under GET_OUT_OF_THE_WAY_AFTER_MINUTES: a job that may yet be satisfied
## somewhere else is not worth throwing a benchmark away for.
run_case "waiter queued 60s ago" no-waiter STUB_PENDING="9001|alice|train-70b|$NODE||60|4294901759|"
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter queued 60s ago, with the wait set to 0" yielded \
    STUB_PENDING="9001|alice|train-70b|$NODE||60|4294901759|" GET_OUT_OF_THE_WAY_AFTER_MINUTES=0

## Held at priority 0: it passes every other condition -- foreign name, this
## node by name, pending for hours -- and will never start.
## docs/explanation/sequencing.md#a-held-job-is-not-a-waiter
run_case "waiter is held after a failed launch" no-waiter \
    STUB_PENDING="132492|cmods|microbenchmark_nccl_nccl_fp8|ink50-dh01-i01-[11-18,28-37]|(null)|75600|0|"
nothing_killed || bad "  ... but a benchmark was thrown away for a job that cannot start"

## An operator's hold is the same priority 0 and the same answer.
run_case "waiter is held by an operator" no-waiter \
    STUB_PENDING="9001      |alice   |train-70b   |$NODE   |    |3600  |0      |"
nothing_killed || bad "  ... but something was cancelled"

## The whole queue held: not "the controller would not answer", which is a
## different result and must not be reached by this path.
run_case "every waiter is held" no-waiter \
    STUB_PENDING="9001|alice|train-70b|$NODE||3600|0|
9002|bob|inference|$NODE||3600|0|"
nothing_killed || bad "  ... but something was cancelled"

## One real waiter behind two held ones: the held lines must be skipped over
## rather than ending the scan.
run_case "a real waiter behind two held ones" yielded \
    STUB_PENDING="9001|alice|train-70b|$NODE||3600|0|
9002|bob|inference|$NODE||3600|0|
9003|carol|sweep|$NODE||3600|4294901759|"
cancelled || bad "  ... but scancel was never called"

## Fail open: a squeue that does not give a number for priority leaves the
## feature exactly as it was before the field was asked for.
run_case "priority field is empty" yielded \
    STUB_PENDING="9001|alice|train-70b|$NODE||3600||"
cancelled || bad "  ... but scancel was never called"

echo "== the job in the marker is not confirmed ours =="

run_case "another user owns it"   not-ours STUB_JOB="4242|bob|bringup-$NODE|RUNNING|$NODE|"
nothing_killed || bad "  ... but somebody else's job was cancelled"

run_case "not a bringup name"     not-ours STUB_JOB="4242|cmods|train-70b|RUNNING|$NODE|"
nothing_killed || bad "  ... but somebody else's job was cancelled"

run_case "another node's bringup" not-ours STUB_JOB="4242|cmods|bringup-othernode|RUNNING|$NODE|"
nothing_killed || bad "  ... but another node's job was cancelled"

run_case "caller named no job of its own" not-ours YIELD_OURS=""
nothing_killed || bad "  ... but a job was cancelled with nothing to compare the name against"

## A caller that vouches for a foreign job: YIELD_OURS is set to the name of a
## real neighbouring job, owned by JOB_USER and running here, so user, id, state
## and node all pass and the name is the only thing left standing between it and
## a scancel. See docs/explanation/sequencing.md#the-prefix-is-the-gate.
run_case "caller vouches for a foreign name" not-ours \
    STUB_JOB="4242|cmods|microbenchmark_nccl_nccl_fp8|RUNNING|$NODE|" \
    YIELD_OURS="microbenchmark_nccl_nccl_fp8"
nothing_killed || bad "  ... but the prefix gate let a foreign job through"

run_case "id does not match the answer" unconfirmed STUB_JOB="4243|cmods|bringup-$NODE|RUNNING|$NODE|"
nothing_killed || bad "  ... but a job we did not ask about was cancelled"

run_case "two answers for one id" unconfirmed \
    STUB_JOB="4242|cmods|bringup-$NODE|RUNNING|$NODE|
4242|cmods|bringup-$NODE|RUNNING|$NODE|"
nothing_killed || bad "  ... but an ambiguous answer was acted on"

run_case "job is pending, not running" not-running STUB_JOB="4242|cmods|bringup-$NODE|PENDING||"
nothing_killed || bad "  ... but a job holding nothing was cancelled"

run_case "job is running elsewhere" elsewhere \
    STUB_JOB="4242|cmods|bringup-$NODE|RUNNING|ink50-dh01-i01-14|"
nothing_killed || bad "  ... but a job on another node was cancelled"

run_case "job has left the queue" gone STUB_JOB=""
nothing_killed || bad "  ... but a job that is not in the queue was cancelled"

run_case "marker holds an unusable id" no-job STUB_WANT="4242-bad"
[[ -f "$CASE_DIR/squeue.calls" ]] && bad "  ... and it asked the controller anyway"

echo "== switches, polling and failures =="

run_case "switched off" disabled GET_OUT_OF_THE_WAY=no
[[ -f "$CASE_DIR/squeue.calls" ]] && bad "  ... and it asked the controller anyway"

run_case "dry run" would-yield YIELD_DRY_RUN=1
nothing_killed || bad "  ... but --explain cancelled a job"
[[ -f "$CASE_DIR/.yield-check" ]] && bad "  ... and --explain wrote the poll stamp"

run_case "the poll stamp is written" yielded
[[ -f "$CASE_DIR/.yield-check" ]] || bad "  ... but no poll stamp was left behind"

## The stamp is what keeps a running cycle off the controller. See
## docs/explanation/sequencing.md#what-a-yield-costs.
setup_stamp=1
run_case "polled a moment ago" polled-recently
[[ -f "$CASE_DIR/squeue.calls" ]] && bad "  ... and it asked the controller anyway"
unset setup_stamp

run_case "the queue cannot be read" no-queue-answer STUB_SQUEUE_FAIL=1
nothing_killed || bad "  ... but it cancelled a job on no information"

run_case "scancel refuses" cancel-failed STUB_SCANCEL_OUT="scancel: error: Kill job error on job id 4242: Access/permission denied"

echo "== the cancel itself =="

## _yield_cancel is the only line in the library that reaches scancel, and it
## re-reads the prefix there rather than trusting the checks that got it here.
## Driven directly, because no caller can reach it with a foreign name.
cancel_case() {
    local name="$1" want="$2" dir="$work/cancel-$((pass + fail))" out
    mkdir -p "$dir"
    out=$(
        export PATH="$stub:$PATH" STUB_DIR="$dir"
        source "$home/settings.sh"
        YIELD_USER=cmods
        source "$home/get-out-of-the-way.sh"
        _yield_cancel 4242 "$name"
    )
    case "$want" in
        refused)
            if [[ "$out" == *"refusing to scancel"* ]] && [[ ! -f "$dir/scancel.calls" ]]; then
                ok "_yield_cancel refuses '$name' and says so"
            else
                bad "_yield_cancel '$name' -> '${out:-<nothing>}'$([[ -f "$dir/scancel.calls" ]] && printf ', and it called scancel')"
            fi ;;
        allowed)
            if [[ -f "$dir/scancel.calls" ]]; then
                ok "_yield_cancel cancels '$name'"
            else
                bad "_yield_cancel '$name' never called scancel"
            fi ;;
    esac
}

cancel_case "bringup-$NODE"                 allowed
cancel_case "burnin-$NODE"                  allowed
cancel_case "microbenchmark_nccl_nccl_fp8"  refused
cancel_case "train-70b"                     refused
cancel_case ""                              refused
## Not a prefix match by accident: the framework's name has to start the string.
cancel_case "not-a-bringup-job"             refused

echo "== dropping to YIELD_USER =="

## The uid decides which half of the cancel runs, and only one of them can be
## exercised per run. Named, so a green suite says which half it proved rather
## than implying both. docs/explanation/sequencing.md#the-prefix-is-the-gate
run_case "the cancel path taken by this uid" yielded YIELD_AFTER_SECS=0
if [[ "$EUID" -eq 0 ]]; then
    [[ -f "$CASE_DIR/su.calls" ]] &&
        ok "root: dropped to YIELD_USER rather than cancelling as itself" ||
        bad "root: cancelled as root, without dropping to YIELD_USER"
else
    [[ -f "$CASE_DIR/su.calls" ]] &&
        bad "uid $EUID: dropped to YIELD_USER without being root" ||
        ok "uid $EUID: cancelled directly (root takes the su path; CI runs as root)"
fi

## What CI hit for real: JOB_USER does not exist on the node. su reports it and
## fails, and the node must not be recorded as given up. Only reachable as root,
## so it is skipped rather than counted where it cannot run.
if [[ "$EUID" -eq 0 ]]; then
    run_case "the user we drop to does not exist" cancel-failed \
        STUB_SU_OUT="su: user cmods does not exist"
    nothing_killed || bad "  ... and it cancelled anyway"
else
    skip "the user we drop to does not exist (needs root; CI runs as root)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

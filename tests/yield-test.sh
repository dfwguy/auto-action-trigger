#!/bin/bash
#
# Checks the gates in get-out-of-the-way.sh, which decides for the whole fleet on
# the head node now rather than per node. The library under test is the real one,
# sourced, and driven by one queue string in the shape snapshot_query hands it:
#
#   id|name|user|state|priority|submit|end|nodelist|reqnodes|schednodes|reason
#
# See docs/explanation/sequencing.md#getting-out-of-the-way.
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

chmod 755 "$stub"/*

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

NODE=ink50-dh01-i01-13
## One clock for the whole suite, so a case's submit times are exact relative to
## it. The library measures every wait against this, not against its own date.
NOW=$(date +%s)
HOUR_AGO=$(date -d "@$(( NOW - 3600 ))" '+%Y-%m-%dT%H:%M:%S')
MIN_AGO=$(date -d "@$(( NOW - 60 ))" '+%Y-%m-%dT%H:%M:%S')
ENDS=$(date -d "@$(( NOW + 3600 ))" '+%Y-%m-%dT%H:%M:%S')

## Our benchmark, running on the node: ours by name, our user's, RUNNING, here.
OURJOB="4242|bringup-$NODE|cmods|RUNNING|4294901759|$HOUR_AGO|$ENDS|$NODE|$NODE||None"
## A foreign job pending for an hour on this node by name, at a priority that is
## not 0 -- 0 is held, and held is not waiting.
WAITER="9001|train-70b|alice|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|$NODE|Resources"

## One case: $1 name, $2 expected YIELD_RESULT, rest VAR=value overrides.
## STUB_QUEUE is the whole fleet queue; it defaults to one waiter and one job of
## ours, which is the case that must cancel.
run_case() {
    local name="$1" want="$2"; shift 2
    local dir="$work/case-$((pass + fail))"
    mkdir -p "$dir/results/$NODE"

    (
        export PATH="$stub:$PATH" STUB_DIR="$dir"
        export STUB_SCANCEL_OUT=""
        STUB_QUEUE="$WAITER
$OURJOB"

        source "$home/settings.sh"
        GET_OUT_OF_THE_WAY=yes
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
        source "$home/slurm-snapshot.sh"
        source "$home/get-out-of-the-way.sh"
        yield_scan "$dir/results" "$STUB_QUEUE" "$NOW" > "$dir/out" 2>&1
        printf '%s' "$YIELD_RESULT" > "$dir/result"
        printf '%s' "$YIELD_CANCELLED" > "$dir/count"
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
breadcrumb()     { [[ -f "$CASE_DIR/results/$NODE/.yielded" ]]; }

echo "== a job is waiting for the node =="

run_case "waiter names the node" scanned
cancelled  || bad "  ... but scancel was never called"
breadcrumb || bad "  ... but the node was left nothing saying why its job went"

## Compressed, and the node is inside the range: proof the list is expanded.
run_case "waiter is scheduled onto the node" scanned \
    STUB_QUEUE="9001|train-70b|alice|PENDING|4294901759|$HOUR_AGO|N/A|||ink50-dh01-i01-[11-18]|Resources
$OURJOB"
cancelled || bad "  ... but scancel was never called"

## Straight off a head node, and the case this feature exists for: the waiter
## runs as JOB_USER too, so only the job name tells it from one of ours, and
## SchedNodes reads `(null)` rather than empty.
run_case "the real queue's waiter" scanned \
    STUB_QUEUE="130938|microbenchmark_nccl_nccl_fp8|cmods|PENDING|4294901759|$HOUR_AGO|N/A||ink50-dh01-i01-[11-18,28-37]|(null)|Resources
130939|bringup-ink50-dh01-i05-31|cmods|PENDING|4294901758|$HOUR_AGO|N/A||ink50-dh01-i05-31|(null)|Priority
$OURJOB"
cancelled || bad "  ... but scancel was never called"

run_case "only jobs of ours are queued" no-waiter \
    STUB_QUEUE="130939|bringup-$NODE|cmods|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|(null)|Priority
130937|burnin-$NODE|cmods|PENDING|4294901758|$HOUR_AGO|N/A||$NODE|(null)|Priority
$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

echo "== nobody is waiting =="

run_case "empty queue"             empty-queue STUB_QUEUE=""
nothing_killed || bad "  ... but something was cancelled"

run_case "nothing pending at all"  no-waiter STUB_QUEUE="$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter is a job of ours" no-waiter \
    STUB_QUEUE="9001|bringup-othernode|cmods|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|$NODE|Priority
$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter wants other nodes" scanned \
    STUB_QUEUE="9001|train-70b|alice|PENDING|4294901759|$HOUR_AGO|N/A||ink50-dh01-i01-[11-12]|(null)|Resources
$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

## Under GET_OUT_OF_THE_WAY_AFTER_MINUTES: a job that may yet be satisfied
## somewhere else is not worth throwing a benchmark away for.
run_case "waiter queued 60s ago" no-waiter \
    STUB_QUEUE="9001|train-70b|alice|PENDING|4294901759|$MIN_AGO|N/A||$NODE|$NODE|Resources
$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

run_case "waiter queued 60s ago, with the wait set to 0" scanned \
    GET_OUT_OF_THE_WAY_AFTER_MINUTES=0 \
    STUB_QUEUE="9001|train-70b|alice|PENDING|4294901759|$MIN_AGO|N/A||$NODE|$NODE|Resources
$OURJOB"
cancelled || bad "  ... but scancel was never called"

## Held at priority 0: it passes every other condition -- foreign name, this
## node by name, pending for hours -- and will never start.
## docs/explanation/sequencing.md#a-held-job-is-not-a-waiter
run_case "waiter is held after a failed launch" no-waiter \
    STUB_QUEUE="132492|microbenchmark_nccl_nccl_fp8|cmods|PENDING|0|$HOUR_AGO|N/A||ink50-dh01-i01-[11-18,28-37]|(null)|launch failed requeued held
$OURJOB"
nothing_killed || bad "  ... but a benchmark was thrown away for a job that cannot start"

run_case "waiter is held by an operator" no-waiter \
    STUB_QUEUE="9001|train-70b|alice|PENDING|0|$HOUR_AGO|N/A||$NODE|$NODE|JobHeldUser
$OURJOB"
nothing_killed || bad "  ... but something was cancelled"

## One real waiter behind two held ones: the held lines must be skipped over
## rather than ending the scan.
run_case "a real waiter behind two held ones" scanned \
    STUB_QUEUE="9001|train-70b|alice|PENDING|0|$HOUR_AGO|N/A||$NODE|$NODE|JobHeldUser
9002|inference|bob|PENDING|0|$HOUR_AGO|N/A||$NODE|$NODE|JobHeldUser
9003|sweep|carol|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|$NODE|Resources
$OURJOB"
cancelled || bad "  ... but scancel was never called"

## Fail open: a queue that does not give a number for priority leaves the
## feature exactly as it was before the field was asked for.
run_case "priority field is empty" scanned \
    STUB_QUEUE="9001|train-70b|alice|PENDING||$HOUR_AGO|N/A||$NODE|$NODE|Resources
$OURJOB"
cancelled || bad "  ... but scancel was never called"

echo "== the running job is not confirmed ours =="

## Every one of these has a real waiter: the only thing standing between it and
## a scancel is what the queue says about the job on the node.
with_waiter() { printf '%s\n%s' "$WAITER" "$1"; }

run_case "another user owns it" scanned \
    STUB_QUEUE="$(with_waiter "4242|bringup-$NODE|bob|RUNNING|4294901759|$HOUR_AGO|$ENDS|$NODE|$NODE||None")"
nothing_killed || bad "  ... but somebody else's job was cancelled"

run_case "not a bringup name" scanned \
    STUB_QUEUE="$(with_waiter "4242|train-70b|cmods|RUNNING|4294901759|$HOUR_AGO|$ENDS|$NODE|$NODE||None")"
nothing_killed || bad "  ... but a foreign job was cancelled"

run_case "ours, but pending rather than running" scanned \
    STUB_QUEUE="$(with_waiter "4242|bringup-$NODE|cmods|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|$NODE|Resources")"
nothing_killed || bad "  ... but a job holding nothing was cancelled"

run_case "ours, but running on another node" scanned \
    STUB_QUEUE="$(with_waiter "4242|bringup-ink50-dh01-i01-14|cmods|RUNNING|4294901759|$HOUR_AGO|$ENDS|ink50-dh01-i01-14|ink50-dh01-i01-14||None")"
nothing_killed || bad "  ... but a job on another node was cancelled"

## A neighbouring node's benchmark, running on a node somebody wants: ours by
## prefix and by user, but it is not on the node being waited for.
run_case "our job elsewhere while this node is wanted" scanned \
    STUB_QUEUE="9001|train-70b|alice|PENDING|4294901759|$HOUR_AGO|N/A||$NODE|$NODE|Resources
4242|bringup-ink50-dh01-i01-99|cmods|RUNNING|4294901759|$HOUR_AGO|$ENDS|ink50-dh01-i01-99|ink50-dh01-i01-99||None"
nothing_killed || bad "  ... but a job on a node nobody is waiting for was cancelled"

echo "== switches, polling and failures =="

run_case "switched off" disabled GET_OUT_OF_THE_WAY=no
nothing_killed || bad "  ... but a switched-off feature cancelled a job"

run_case "dry run" scanned YIELD_DRY_RUN=1
nothing_killed || bad "  ... but --explain cancelled a job"
[[ -f "$CASE_DIR/.yield-check" ]] && bad "  ... and --explain wrote the poll stamp"
breadcrumb && bad "  ... and --explain left the node a breadcrumb for a cancel that did not happen"

run_case "the poll stamp is written" scanned
[[ -f "$CASE_DIR/.yield-check" ]] || bad "  ... but no poll stamp was left behind"

## The stamp is the last gate in front of the one destructive thing here.
## See docs/explanation/sequencing.md#what-a-yield-costs.
setup_stamp=1
run_case "polled a moment ago" polled-recently
nothing_killed || bad "  ... but it cancelled inside its own poll interval"
unset setup_stamp

run_case "scancel refuses" scanned \
    STUB_SCANCEL_OUT="scancel: error: Kill job error on job id 4242: Access/permission denied"
breadcrumb && bad "  ... but a refused cancel still told the node it had been yielded"

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

echo "== the cancel runs as this cycle =="

## There is no drop to YIELD_USER -- the watchdog is already that account, so
## `su` is never called whoever runs the suite.
## docs/explanation/running-unprivileged.md#the-cancel-runs-as-the-cycle
run_case "the cancel path" scanned
[[ -f "$CASE_DIR/su.calls" ]] &&
    bad "uid $EUID: went through su, which nothing should do now" ||
    ok "uid $EUID: cancelled directly, as $(id -un)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

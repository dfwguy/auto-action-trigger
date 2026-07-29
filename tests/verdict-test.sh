#!/bin/bash
#
# Usage: tests/verdict-test.sh
#
# Checks verdict.sh against captured result files in tests/fixtures/.
#
# This exists because a gate that is wrong is invisible until it has already
# passed or drained the whole cluster, and that has now happened twice. The
# expensive one was allreduce-nonvlink/alltoall-nonvlink running entirely over
# TCP at ~1.2 GB/s while reporting DONE on 25 nodes; the gate written to catch
# it was correct, but nothing re-judged the results it was written for.
#
# Fixtures are named <job>__<case>.txt. The job name before the double
# underscore is what gets handed to verdict(), so a fixture exercises the same
# dispatch a real result file would.
#
# Adding a case is one fixture file plus one line in the table below. When a
# gate rejects something it should not have, capture that node's result file
# here before changing the rule -- that is what stops the next change to
# verdict.sh from quietly undoing this one.

## The fixtures were captured on nvl72 hardware and the expectations below are
## that platform's gates, so this tests parsers/nvl72 specifically rather than
## whatever PARSERS happens to be set to. A site that switches PARSERS wants a
## second fixture set, not this one silently re-pointed at its parser.
home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$home/parsers/nvl72/verdict.sh"

## fixture | expected status | expected reason (empty for DONE)
##
## The reason is asserted, not just the status. A gate that rejects a socket run
## for the wrong reason -- because the bandwidth happened to be low rather than
## because the transport was wrong -- would still fail it today and still pass
## it the moment someone raises the floor.
cases=(
  ## The real h01-14 run, from before the container probe existed. It has no
  ## `container sees HCAs` line, so the earliest cause the log does carry is
  ## reported instead -- not the TCP fallback further down, which is the
  ## consequence rather than the reason.
  "alltoall-nonvlink__socket-legacy-done|FAIL|no IB device visible to NCCL"
  "alltoall-nonvlink__good-ib|DONE|"
  ## Host list complete and correct, container sees nothing. Reported against
  ## the probe rather than the socket fallback further down the log, because
  ## that is the cause and the rest is consequence.
  "alltoall-nonvlink__container-blind|FAIL|no HCA visible inside the container"
  "allreduce-nonvlink__ib-below-floor|FAIL|avg bus bandwidth below floor 10 GB/s"
  "alltoall__truncated|INCOMPLETE|no end marker -- job died before finishing"
  "allreduce__fell-to-socket|FAIL|collective left NVLink for the network"
  ## The real h20-36 run: 32 channels of via P2P/MNNVL at 220.837 GB/s, and it
  ## still logs `NET/IB : No device found.`, `NET/Socket : Using` and `Using
  ## network Socket` while doing it -- NCCL registers a net plugin whether or
  ## not it uses one. Forbidding those strings failed this run as "collective
  ## carried over TCP". Keep this fixture; it is the whole argument for judging
  ## the per-channel `via ...` lines and nothing else.
  "allreduce__good-nvlink|DONE|"
  "dcgm__pass|DONE|"
  "dcgm__gpu-failure|FAIL|dcgmi subtest failed: Targeted Stress"
  "dcgm__no-output|FAIL|no dcgmi Pass row"
  ## The real h03-16 run, and the reason a self-reported FAIL is now explained
  ## rather than just repeated. `dcgmi diag` exits 226 on a failed subtest, so
  ## the sbatch -- which decides only whether the job RAN -- writes FAIL, and
  ## every one of the fifty nodes in this state reported `job reported FAIL`
  ## with the cause sitting in the table three lines up. The verdict has to name
  ## the subtest, and it has to name it without the per-GPU text, which differs
  ## between nodes and would stop dshbak collapsing them.
  "dcgm__targeted-power|FAIL|dcgmi subtest failed: targeted_power"
  ## The real h01-13 run, and the reason _v_gate_nvbandwidth exists. Every peer
  ## matrix in it carries N/A down the diagonal -- a GPU has no transfer with
  ## itself -- and the rule this replaced was a flat `grep -iE "N/A"`, so this
  ## healthy node was failed, as was every other node with more than one GPU.
  ##
  ## Only the end marker differs from what was captured: the sbatch wrote its
  ## own FAIL there, which is the half of the bug that made it stick. A
  ## self-reported FAIL is never re-judged, so those results cannot be rescued
  ## by this fixture passing -- they have to be re-run. Keep this file; it is
  ## the whole argument for checking N/A by position rather than as a string.
  "nvbandwidth__good|DONE|"
  ## Same capture, one off-diagonal cell blanked: GPU 1 cannot reach GPU 2.
  ## That is the fault section 6.2 asks about, and it has to still be caught.
  "nvbandwidth__missing-peer|FAIL|missing peer transfer -- N/A off the matrix diagonal"
  "nvbandwidth__unstable|FAIL|bandwidth unstable -- coefficient of variation above 0.08"
  "example__good|DONE|"
  ## The other half of the `exit status:` line every job now prints before its
  ## marker. Here it is non-zero, and the FAIL is the job's own: the step hit
  ## its --time limit and srun returned 143. `example__good` carries the same
  ## line at 0 and still passes its gate -- between them they hold the line to
  ## a wording no gate reacts to, which is the thing that could silently break.
  ##
  ## Reported as the run error the log carries, not as `job reported FAIL`: the
  ## self-reported marker fixes the STATUS, and the reason is read out of the
  ## log underneath it.
  "example__step-cancelled|FAIL|run error"
)

pass=0
fail=0

for case in "${cases[@]}"; do
    IFS='|' read -r fixture want_status want_reason <<<"$case"
    file="$home/tests/fixtures/${fixture}.txt"
    job="${fixture%%__*}"

    if [[ ! -f "$file" ]]; then
        printf 'MISSING  %-42s no such fixture\n' "$fixture"
        ((fail++))
        continue
    fi

    verdict "$job" "$file"

    if [[ "$VERDICT_STATUS" != "$want_status" ]]; then
        printf 'FAIL     %-42s status: want %s, got %s (%s)\n' \
            "$fixture" "$want_status" "$VERDICT_STATUS" "$VERDICT_REASON"
        ((fail++))
    elif [[ "$VERDICT_REASON" != "$want_reason" ]]; then
        printf 'FAIL     %-42s reason: want "%s", got "%s"\n' \
            "$fixture" "$want_reason" "$VERDICT_REASON"
        ((fail++))
    else
        printf 'ok       %-42s %s%s\n' \
            "$fixture" "$VERDICT_STATUS" "${VERDICT_REASON:+ -- $VERDICT_REASON}"
        ((pass++))
    fi
done

## A verdict has to survive a result file that is not one of ours -- an empty
## file, a directory that got there by accident, a path that does not exist.
## None of these should be a pass and none should error.
verdict "allreduce" "$home/tests/fixtures/does-not-exist.txt"
if [[ "$VERDICT_STATUS" == "NOT_RUN" ]]; then
    printf 'ok       %-42s NOT_RUN\n' "(missing file)"
    ((pass++))
else
    printf 'FAIL     %-42s want NOT_RUN, got %s\n' "(missing file)" "$VERDICT_STATUS"
    ((fail++))
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

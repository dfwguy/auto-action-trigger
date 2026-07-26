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

home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$home/verdict.sh"

## fixture | expected status | expected reason (empty for DONE)
##
## The reason is asserted, not just the status. A gate that rejects a socket run
## for the wrong reason -- because the bandwidth happened to be low rather than
## because the transport was wrong -- would still fail it today and still pass
## it the moment someone raises the floor.
cases=(
  "alltoall-nonvlink__socket-legacy-done|FAIL|collective carried over TCP"
  "alltoall-nonvlink__good-ib|DONE|"
  "allreduce-nonvlink__ib-below-floor|FAIL|avg bus bandwidth below floor 10 GB/s"
  "alltoall__truncated|INCOMPLETE|no end marker -- job died before finishing"
  "allreduce__fell-to-socket|FAIL|collective carried over TCP"
  "allreduce__good-nvlink|DONE|"
  "dcgm__pass|DONE|"
  "dcgm__gpu-failure|FAIL|dcgmi fail/warn/error"
  "dcgm__no-output|FAIL|no dcgmi Pass row"
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

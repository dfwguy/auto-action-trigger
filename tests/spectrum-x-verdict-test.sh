#!/bin/bash
#
# Usage: tests/spectrum-x-verdict-test.sh
#
# Checks parsers/spectrum-x/verdict.sh's NCCL gate against captured spectrum-x
# result files in tests/fixtures/. Mirrors tests/verdict-test.sh, scoped to the
# one thing that differs from parsers/nvl72/verdict.sh: allreduce-nonvlink and
# alltoall-nonvlink require SPCX, not IB, as the chosen network. See
# docs/reference/settings.md#which-set-of-things-to-run.
#
# Fixtures are named <job>__spcx-<case>.txt -- the part before the double
# underscore is what gets handed to verdict().
home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

## Not shipped anywhere yet -- no spectrum-x fleet has established a floor.
## 90 sits between the captured good run (94.42 GB/s) and the edited
## below-floor fixture (45.10 GB/s), same relationship as the nvl72 floors.
##
## SC2034: read by verdict.sh, sourced below, which shellcheck cannot see from
## here.
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK=90
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK=90

source "$home/parsers/spectrum-x/verdict.sh"

## fixture | expected status | expected reason (empty for DONE)
cases=(
  ## Real br-msp2-b300-td1-su1-01, trimmed to rank 0. The capture that
  ## motivated this parser: nvl72's verdict.sh required `Using network IB`,
  ## which a spectrum-x log never prints.
  "allreduce-nonvlink__spcx-good|DONE|"
  "allreduce-nonvlink__spcx-below-floor|FAIL|peak busbw below floor 90 GB/s"
  ## SPCX plugin fails to load and NCCL falls back to Socket -- caught before
  ## reaching the "not chosen" check, same ordering as nvl72's IB chain.
  "allreduce-nonvlink__spcx-plugin-failed|FAIL|SPCX plugin failed to load"
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

## alltoall-nonvlink routes to the same gate as allreduce-nonvlink -- confirm
## it also requires SPCX rather than falling through to a default that passes
## everything, same shape as the dcgmi routing check in verdict-test.sh.
verdict "alltoall-nonvlink" "$home/tests/fixtures/allreduce-nonvlink__spcx-plugin-failed.txt"
if [[ "$VERDICT_STATUS" == "FAIL" && "$VERDICT_REASON" == "SPCX plugin failed to load" ]]; then
    printf 'ok       %-42s FAIL -- %s\n' "(alltoall-nonvlink routes to the gate)" "$VERDICT_REASON"
    ((pass++))
else
    printf 'FAIL     %-42s want FAIL naming SPCX, got %s / %s\n' \
        "(alltoall-nonvlink routes to the gate)" "$VERDICT_STATUS" "$VERDICT_REASON"
    ((fail++))
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

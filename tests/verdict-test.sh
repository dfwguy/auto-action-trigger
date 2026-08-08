#!/bin/bash
#
# Usage: tests/verdict-test.sh
#
# Checks verdict.sh against captured result files in tests/fixtures/. A wrong
# gate is invisible until it has already passed or drained the cluster; see
# docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
#
# Fixtures are named <job>__<case>.txt -- the part before the double underscore
# is what gets handed to verdict(). Adding a case is one fixture file plus one
# line in the table below; when a gate rejects something it should not have,
# capture that node's result file here before changing the rule.

## Pinned to parsers/nvl72 rather than $PARSERS: the fixtures are nvl72
## captures. A site that switches PARSERS wants its own fixture set.
home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

## Pinned, not sourced from SETTINGS: a site that re-floors a job must not
## change what these fixtures assert. `shipped floors` below checks they agree.
##
## SC2034: read by verdict.sh, sourced below, which shellcheck cannot see from
## here. Repeated because it covers only the next assignment.
VERDICT_MIN_PEAK_BW_ALLREDUCE=683
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP=665
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLTOALL=623
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK=93
# shellcheck disable=SC2034
VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK=83

source "$home/parsers/nvl72/verdict.sh"

## fixture | expected status | expected reason (empty for DONE)
##
## The reason is asserted, not just the status: a socket run rejected for low
## bandwidth rather than wrong transport still passes the moment a floor moves.
cases=(
  ## Real h01-14, from before the container probe existed -- the earliest cause
  ## the log carries, not the TCP fallback that is its consequence.
  "alltoall-nonvlink__socket-legacy-done|FAIL|no IB device visible to NCCL"
  ## Every IB transport check clears here; bandwidth alone rejects it. Stands in
  ## for a DONE case -- no captured -nonvlink run reaches its floor.
  "alltoall-nonvlink__ib-below-floor-32|FAIL|peak busbw below floor 83 GB/s"
  ## Host list complete, container sees nothing. See
  ## docs/explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas.
  "alltoall-nonvlink__container-blind|FAIL|no HCA visible inside the container"
  ## Largest-size busbw is judged; the `# Avg bus bandwidth` line is not.
  "allreduce-nonvlink__ib-below-floor|FAIL|peak busbw below floor 93 GB/s"
  "alltoall__truncated|INCOMPLETE|no end marker -- job died before finishing"
  "allreduce__fell-to-socket|FAIL|collective left NVLink for the network"
  ## Real h20-36: a healthy 220.837 GB/s NVLink run that still logs `Using
  ## network Socket`. Keep it -- it is the argument for
  ## docs/explanation/judging-benchmarks.md#judge-the-channels-never-the-plugin-registration.
  "allreduce__good-nvlink|DONE|"
  "dcgmi-r3__pass|DONE|"
  "dcgmi-r3__gpu-failure|FAIL|dcgmi subtest failed: Targeted Stress"
  "dcgmi-r3__no-output|FAIL|no dcgmi Pass row"
  ## Real h03-16: a self-reported FAIL explained rather than repeated. Names the
  ## subtest without the per-GPU text, which differs between nodes and would
  ## stop dshbak collapsing them.
  "dcgmi-r3__targeted-power|FAIL|dcgmi subtest failed: targeted_power"
  ## Real h01-13: a healthy node that a flat `grep -iE "N/A"` failed on the
  ## matrix diagonal. Keep it -- it is the argument for
  ## docs/explanation/judging-benchmarks.md#judge-what-the-tool-means-not-what-it-says. Only the end
  ## marker differs from the capture, which wrote the sbatch's own FAIL.
  "nvbandwidth__good|DONE|"
  ## Same capture, one off-diagonal cell blanked: the fault 6.2 actually asks
  ## about, and it still has to be caught.
  "nvbandwidth__missing-peer|FAIL|missing peer transfer -- N/A off the matrix diagonal"
  "nvbandwidth__unstable|FAIL|bandwidth unstable -- coefficient of variation above 0.08"
  ## Synthetic; replace with captures once a node has run it. See docs/explanation/llmb.md.
  "llm-pretrain-solo__good|DONE|"
  "llm-pretrain-solo__missing-rank|FAIL|fewer than 4 GPUs reported step timings"
  ## Caught by the SHIPPED floor, which was 0 -- check skipped -- until a healthy
  ## tray gave one. See docs/explanation/llmb.md#judging-the-four-step-times.
  "llm-pretrain-solo__slow-gpu|FAIL|per-GPU step times disagree -- spread above 0.02"
  "example__good|DONE|"
  ## Non-zero `exit status:` line, paired with example__good at 0: between them
  ## they hold that line to a wording no gate reacts to. Reported as the run
  ## error the log carries, not as `job reported FAIL`.
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

## The four dcgmi levels share one gate, and only one of them has fixtures. A
## level missing from verdict.sh's case arm would fall through to the default
## and pass everything. See docs/reference/jobs.md#the-dcgmi-gates.
for level in 1 2 3 4; do
    verdict "dcgmi-r$level" "$home/tests/fixtures/dcgmi-r3__gpu-failure.txt"
    if [[ "$VERDICT_STATUS" == "FAIL" ]]; then
        printf 'ok       %-42s FAIL -- %s\n' "(dcgmi-r$level routes to the gate)" "$VERDICT_REASON"
        ((pass++))
    else
        printf 'FAIL     %-42s want FAIL, got %s -- no gate for this level\n' \
            "(dcgmi-r$level routes to the gate)" "$VERDICT_STATUS"
        ((fail++))
    fi
done

## Shipping 0 and shipping a broken spread check look identical above, so set a
## band and require the outlier to be caught AND named.
## See docs/explanation/llmb.md#judging-the-four-step-times.
_solo_cov_saved="$VERDICT_MAX_COV_LLM_SOLO"
VERDICT_MAX_COV_LLM_SOLO=0.05
verdict "llm-pretrain-solo" "$home/tests/fixtures/llm-pretrain-solo__slow-gpu.txt"
if [[ "$VERDICT_STATUS" == "FAIL" &&
      "$VERDICT_REASON" == "per-GPU step times disagree -- spread above 0.05" &&
      "$VERDICT_DETAIL" == *"slowest gpu 2"* ]]; then
    printf 'ok       %-42s FAIL -- %s\n' "(solo spread, band set)" "$VERDICT_DETAIL"
    ((pass++))
else
    printf 'FAIL     %-42s want FAIL naming gpu 2, got %s / %s / %s\n' \
        "(solo spread, band set)" "$VERDICT_STATUS" "$VERDICT_REASON" "$VERDICT_DETAIL"
    ((fail++))
fi
## Restored so nothing below sees a band the tree does not ship.
VERDICT_MAX_COV_LLM_SOLO="$_solo_cov_saved"

## An empty floor used to skip the bandwidth check -- a silent pass on a
## fixture that clears every other one.
_ar_saved="$VERDICT_MIN_PEAK_BW_ALLREDUCE"
VERDICT_MIN_PEAK_BW_ALLREDUCE=""
verdict "allreduce" "$home/tests/fixtures/allreduce__good-nvlink.txt"
if [[ "$VERDICT_STATUS" == "FAIL" &&
      "$VERDICT_REASON" == "bandwidth floor is not set -- check SETTINGS" ]]; then
    printf 'ok       %-42s FAIL -- %s\n' "(floor unset)" "$VERDICT_REASON"
    ((pass++))
else
    printf 'FAIL     %-42s want the unset-floor reason, got %s / %s\n' \
        "(floor unset)" "$VERDICT_STATUS" "$VERDICT_REASON"
    ((fail++))
fi
VERDICT_MIN_PEAK_BW_ALLREDUCE="$_ar_saved"

## A result file that is not one of ours -- missing, empty, a directory -- must
## be neither a pass nor an error.
verdict "allreduce" "$home/tests/fixtures/does-not-exist.txt"
if [[ "$VERDICT_STATUS" == "NOT_RUN" ]]; then
    printf 'ok       %-42s NOT_RUN\n' "(missing file)"
    ((pass++))
else
    printf 'FAIL     %-42s want NOT_RUN, got %s\n' "(missing file)" "$VERDICT_STATUS"
    ((fail++))
fi

## SETTINGS.default and settings.sh ship the same five numbers and drift
## silently. Checked against the values pinned at the top.
drift=""
_floors=("${!VERDICT_MIN_PEAK_BW_@}")
for _f in "${_floors[@]}"; do
    grep -qx "$_f=${!_f}" "$home/SETTINGS.default"        || drift+=" SETTINGS.default:$_f"
    grep -qx ": \"\${$_f:=${!_f}}\"" "$home/settings.sh"  || drift+=" settings.sh:$_f"
done
if [[ -z "$drift" ]]; then
    printf 'ok       %-42s %s floors agree\n' "(shipped floors)" "${#_floors[@]}"
    ((pass++))
else
    printf 'FAIL     %-42s disagree with the fixtures:%s\n' "(shipped floors)" "$drift"
    ((fail++))
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

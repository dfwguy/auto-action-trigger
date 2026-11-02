#!/bin/bash

## Fixture-based read-only rack validation. No cluster or real Slurm commands.
## See docs/how-to/explain-nvloom-rack.md.
home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
check() {
    if "$@"; then
        printf 'ok       %s\n' "$label"; pass=$((pass + 1))
    else
        printf 'FAIL     %s\n%s\n' "$label" "${out:-}"; fail=$((fail + 1))
    fi
}
mkdir -p "$work/bin" "$work/site"
export SETTINGS_HOME="$work/site" RACK_TEST_FIXTURES="$home/tests/fixtures/rack"
export FORBIDDEN_CALL="$work/forbidden"
cat > "$work/bin/scontrol" <<'STUB'
#!/bin/bash
if [[ "$1 $2" != 'show hostnames' || $# -ne 3 ]]; then
    touch "$FORBIDDEN_CALL"; exit 97
fi
[[ "${RACK_TEST_EXPAND:-}" == failed ]] && { echo 'expansion failed'; exit 1; }
[[ "${RACK_TEST_EXPAND:-}" == empty ]] && exit 0
case "$3" in
    'node[01-18]') printf 'node%02d\n' {1..18} ;;
    'node[01-17]') printf 'node%02d\n' {1..17} ;;
    'node[01-19]') printf 'node%02d\n' {1..19} ;;
    'node[01-18],node01') printf 'node%02d\n' {1..18} 1 ;;
    'node[01-17],node01') printf 'node%02d\n' {1..17} 1 ;;
    'node[01-17],node19') printf 'node%02d\n' {1..17} 19 ;;
    'node[01-17],unknown') printf 'node%02d\n' {1..17}; echo unknown ;;
    *) exit 1 ;;
esac
STUB
cat > "$work/bin/sinfo" <<'STUB'
#!/bin/bash
[[ "$*" == '-N -h -o %N' ]] || { touch "$FORBIDDEN_CALL"; exit 97; }
case "${RACK_TEST_SLURM:-}" in
    failed) echo 'controller unavailable'; exit 1 ;;
    empty) exit 0 ;;
    missing) head -n 17 "$RACK_TEST_FIXTURES/slurm-nodes.txt" ;;
    *) cat "$RACK_TEST_FIXTURES/slurm-nodes.txt" ;;
esac
STUB
for tool in sbatch scancel srun systemctl; do
    cat > "$work/bin/$tool" <<'STUB'
#!/bin/bash
touch "$FORBIDDEN_CALL"
exit 97
STUB
done
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH"
unset SBATCH_NODES RACK_TEST_EXPAND RACK_TEST_SLURM RUN_RACK_JOBS RACK_SAMPLES
settings() {
    printf 'BRINGUP_DATA=%q\nRACK_ID=rack-a\nRACK_NODES=%q\nRACK_MEMBERSHIP_FILE=%q\n' \
        "$work/runtime-must-not-exist" 'node[01-18]' "$RACK_TEST_FIXTURES/membership.tsv" > "$SETTINGS_HOME/SETTINGS"
    printf 'RUN_JOBS=yes\nEXCLUDE_NODES=\nNODE_FILTER=\n' >> "$SETTINGS_HOME/SETTINGS"
}
run() { out=$(bash "$home/actions/launch_rack_job.sh" --explain "$@" 2>&1); rc=$?; }
contains() { [[ "$out" == *"$1"* ]]; }
settings
while IFS=$'\t' read -r label nodes expected diagnostic; do
    run --nodes "$nodes"
    check test "$rc" -eq "$expected"
    label="$label diagnostic"; check contains "$diagnostic"
    if [[ "$expected" -ne 0 ]]; then
        label="$label withholds command"; check contains 'Proposed submission: withheld'
    fi
done < "$RACK_TEST_FIXTURES/selections.tsv"
run
label='automatic scheduling defaults off'; check contains 'RUN_RACK_JOBS=no'
label='sample count defaults to five'; check contains 'RACK_SAMPLES=5'
label='source path shown'; check contains "Membership source: $RACK_TEST_FIXTURES/membership.tsv"
label='all expanded nodes shown'; check contains $'  node18\n'
command_line=$(printf '%s\n' "$out" | sed -n '/^  env /p')
expected_list=$(printf 'node%02d,' {1..18}); expected_list=${expected_list%,}
printf -v expected_list '%q' "$expected_list"
proposal_exact() { [[ "$command_line" == *" sbatch -w $expected_list "* ]]; }
label='proposal uses exact list through -w'; check proposal_exact
label='proposal has no allocation count option'; check test "$command_line" = "${command_line//--nodes/}"
label='proposal has no short count option'; check test "$command_line" = "${command_line// -N/}"
label='output pattern preserved'; check contains '/nvloom-rack-%j.txt'
run --membership-file "$work/missing.tsv"
label='missing membership inventory rejected'; check test "$rc" -eq 1
label='missing inventory explained'; check contains 'membership inventory unavailable'
: > "$work/empty.tsv"
run --membership-file "$work/empty.tsv"
label='empty inventory rejected'; check contains 'invalid membership header'
printf 'node\track_id\tnvlink_domain_id\nnode01\t\tdomain-a\n' > "$work/bad.tsv"
run --membership-file "$work/bad.tsv"
label='empty field rejected'; check contains 'malformed membership row'
cat "$RACK_TEST_FIXTURES/membership.tsv" > "$work/duplicate.tsv"
printf 'node01\track-a\tdomain-a\n' >> "$work/duplicate.tsv"
run --membership-file "$work/duplicate.tsv"
label='duplicate inventory rows rejected'; check contains 'duplicate membership row'
sed 's/domain-b/domain-a/' "$RACK_TEST_FIXTURES/membership.tsv" > "$work/oversized.tsv"
run --membership-file "$work/oversized.tsv"
label='larger mapped domain rejected'; check contains 'has 36 mapped members'
## One member in another domain while retaining the same physical rack.
sed 's/^node18\track-a\tdomain-a$/node18\track-a\tdomain-other/' \
    "$RACK_TEST_FIXTURES/membership.tsv" > "$work/same-rack.tsv"
run --membership-file "$work/same-rack.tsv"
label='mixed domains within one physical rack rejected'; check contains 'mixed NVLink rack/domain membership'
for mode in failed empty missing; do
    export RACK_TEST_SLURM="$mode"
    run
    label="Slurm inventory $mode rejected"; check test "$rc" -eq 1
done
unset RACK_TEST_SLURM
for mode in failed empty; do
    export RACK_TEST_EXPAND="$mode"
    run
    label="hostlist expansion $mode rejected"; check test "$rc" -eq 1
done
unset RACK_TEST_EXPAND
for samples in 0 -1 five ''; do
    settings
    printf 'RACK_SAMPLES=%q\n' "$samples" >> "$SETTINGS_HOME/SETTINGS"
    run
    label="invalid samples '$samples' rejected"; check contains 'RACK_SAMPLES must be a positive integer'
done
settings
printf 'RUN_JOBS=no\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='global pause blocks manual proposal'; check contains 'RUN_JOBS=no: global pause'
settings
printf 'RUN_RACK_JOBS=yes\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='automatic opt-in still only explains'; check test "$rc" -eq 0
label='automatic opt-in does not claim scheduling'; check contains 'requested; not implemented'
settings
printf 'EXCLUDE_NODES=node18\nNODE_FILTER="node0*"\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='exclusion honored'; check contains 'excluded node: node18'
label='filter honored'; check contains 'filtered node:'
settings
SBATCH_NODES=18 run
label='inherited allocation count blocked'; check contains 'SBATCH_NODES is set'
run --rack-id other
label='physical rack selection checked'; check contains 'physical rack mismatch'
for switch in RUN_JOBS RUN_RACK_JOBS; do
    settings
    printf '%s=typo\n' "$switch" >> "$SETTINGS_HOME/SETTINGS"
    run
    label="invalid $switch rejected"; check test "$rc" -eq 1
done
settings
printf 'JOBS=h200x2\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='missing configured rack launcher explained'; check contains 'missing rack launcher:'
settings
run --samples 7
label='sample override used in proposal'; check contains 'RACK_SAMPLES=7 sbatch'
run --samples
label='missing option argument rejected'; check test "$rc" -eq 2
run --submit
label='submission option rejected'; check test "$rc" -eq 2
label='no mutating commands called'; check test ! -e "$FORBIDDEN_CALL"
label='no runtime directories or records created'; check test ! -e "$work/runtime-must-not-exist"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

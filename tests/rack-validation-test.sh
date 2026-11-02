#!/bin/bash

## Live identity validation against synthetic nvidia-smi output and remote tools.
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
export FORBIDDEN_CALL="$work/forbidden" PROBE_CALLS="$work/probes"
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
cat > "$work/bin/nvidia-smi" <<'STUB'
#!/bin/bash
[[ "$*" == '-q' ]] || { touch "$FORBIDDEN_CALL"; exit 97; }
fixture="$RACK_TEST_FIXTURES/nvidia-smi-q.txt"
if [[ "$RACK_TEST_NODE" == node18 ]]; then
    case "${RACK_TEST_PROBE:-}" in
        failed) echo 'driver query failed' >&2; exit 9 ;;
        empty) exit 0 ;;
        mixed) sed 's/53a24e94/63a24e94/g' "$fixture"; exit ;;
        within-node) sed '0,/53a24e94/s//63a24e94/' "$fixture"; exit ;;
        missing-field) sed '0,/ClusterUUID/d' "$fixture"; exit ;;
        na) sed 's/53a24e94-52fa-f566-aa13-60ef67933749/N\/A/g' "$fixture"; exit ;;
        zero) sed 's/53a24e94-52fa-f566-aa13-60ef67933749/00000000-0000-0000-0000-000000000000/g' "$fixture"; exit ;;
        malformed) sed 's/53a24e94-52fa-f566-aa13-60ef67933749/not-a-uuid/g' "$fixture"; exit ;;
        upper) tr 'a-f' 'A-F' < "$fixture"; exit ;;
        duplicate-field) cat "$fixture"; grep -m1 ClusterUUID "$fixture"; exit ;;
    esac
fi
cat "$fixture"
STUB
cat > "$work/bin/clush" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$PROBE_CALLS"
[[ "$*" == *'-t 10 -u 60'* ]] || { touch "$FORBIDDEN_CALL"; exit 97; }
nodes=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -w) nodes=$2; shift 2 ;;
        --) shift; break ;;
        -t|-u|-R) shift 2 ;;
        *) break ;;
    esac
done
command=$1
[[ "$command" == *'nvidia-smi -q'* ]] || { touch "$FORBIDDEN_CALL"; exit 97; }
[[ "${RACK_TEST_PROBE:-}" == timeout ]] && exit 124
IFS=, read -r -a members <<< "$nodes"
for node in "${members[@]}"; do
    [[ "${RACK_TEST_PROBE:-}" == missing-node && "$node" == node18 ]] && continue
    output=$(RACK_TEST_NODE="$node" bash -c "$command" 2>&1)
    while IFS= read -r line; do
        [[ "${RACK_TEST_PROBE:-}" == clipped && "$node" == node18 && "$line" == __NVLOOM_PROBE_EXIT__=* ]] && continue
        printf '%s: %s\n' "$node" "$line"
    done <<< "$output"
    if [[ "${RACK_TEST_PROBE:-}" == duplicate-completion && "$node" == node18 ]]; then
        printf '%s: __NVLOOM_PROBE_EXIT__=0\n' "$node"
    fi
done
[[ "${RACK_TEST_PROBE:-}" == transport-failure ]] && exit 1
exit 0
STUB
cp "$work/bin/clush" "$work/bin/pdsh"
for tool in sbatch scancel srun systemctl; do
    cat > "$work/bin/$tool" <<'STUB'
#!/bin/bash
touch "$FORBIDDEN_CALL"
exit 97
STUB
done
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH"
unset SBATCH_NODES RACK_TEST_EXPAND RACK_TEST_SLURM RACK_TEST_PROBE RUN_RACK_JOBS RACK_SAMPLES
settings() {
    printf 'BRINGUP_DATA=%q\nRACK_ID=rack-a\nRACK_NODES=%q\n' \
        "$work/runtime-must-not-exist" 'node[01-18]' > "$SETTINGS_HOME/SETTINGS"
    printf 'RUN_JOBS=yes\nEXCLUDE_NODES=\nNODE_FILTER=\nFANOUT_TOOL=clush\nFANOUT_CONNECT_TIMEOUT=10\nFANOUT_COMMAND_TIMEOUT=60\n' >> "$SETTINGS_HOME/SETTINGS"
}
run() { out=$(bash "$home/actions/launch_rack_job.sh" --explain "$@" 2>&1); rc=$?; }
contains() { [[ "$out" == *"$1"* ]]; }
selection() {
    local name=$1 nodes=$2 expected=$3 diagnostic=$4
    run --nodes "$nodes"
    label="$name status"; check test "$rc" -eq "$expected"
    label="$name diagnostic"; check contains "$diagnostic"
    if [[ "$expected" -ne 0 ]]; then
        label="$name withholds command"; check contains 'Proposed submission: withheld'
    fi
}
settings
selection valid 'node[01-18]' 0 'VALID: exactly 18'
probe_count=$(wc -l < "$PROBE_CALLS")
selection 'wrong count' 'node[01-17]' 1 'expected exactly 18 distinct nodes; found 17'
selection oversized 'node[01-19]' 1 'expected exactly 18 distinct nodes; found 19'
selection duplicate 'node[01-18],node01' 1 'duplicate selected node: node01'
selection 'duplicate masking count' 'node[01-17],node01' 1 'expected exactly 18 distinct nodes; found 17'
label='invalid counts and duplicates do not trigger remote probes'; check test "$(wc -l < "$PROBE_CALLS")" -eq "$probe_count"
selection 'hostname patterns do not define membership' 'node[01-17],node19' 0 'VALID: exactly 18'
selection 'unknown node' 'node[01-17],unknown' 1 'selected node absent from Slurm inventory: unknown'
run
label='automatic scheduling defaults off'; check contains 'RUN_RACK_JOBS=no'
label='sample count defaults to five'; check contains 'RACK_SAMPLES=5'
label='live source shown'; check contains 'Membership source: live nvidia-smi -q ClusterUUID via fanout.sh'
label='all expanded nodes and identities shown'; check contains 'node18  ClusterUUID=53a24e94-52fa-f566-aa13-60ef67933749'
command_line=$(printf '%s\n' "$out" | sed -n '/^  env /p')
expected_list=$(printf 'node%02d,' {1..18}); expected_list=${expected_list%,}
printf -v expected_list '%q' "$expected_list"
proposal_exact() { [[ "$command_line" == *" sbatch -w $expected_list "* ]]; }
label='proposal uses exact list through -w'; check proposal_exact
label='proposal has no allocation count option'; check test "$command_line" = "${command_line//--nodes/}"
label='proposal has no short count option'; check test "$command_line" = "${command_line// -N/}"
label='output pattern preserved'; check contains '/nvloom-rack-%j.txt'
for mode in mixed within-node failed empty missing-field na zero malformed duplicate-field missing-node clipped duplicate-completion timeout transport-failure; do
    export RACK_TEST_PROBE="$mode"
    run
    label="$mode evidence blocks validation"; check test "$rc" -eq 1
    label="$mode evidence withholds command"; check contains 'Proposed submission: withheld'
done
RACK_TEST_PROBE=mixed run
label='mismatch names node and identity'; check contains 'mixed NVLink domains: node18 ClusterUUID=63a24e94'
RACK_TEST_PROBE=within-node run
label='within-node disagreement explained'; check contains 'GPUs disagree on ClusterUUID'
RACK_TEST_PROBE=failed run
label='remote failure checked even when fan-out exits zero'; check contains 'nvidia-smi probe failed (exit 9)'
RACK_TEST_PROBE=upper run
label='UUID comparison ignores hex letter case'; check test "$rc" -eq 0
unset RACK_TEST_PROBE
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
run --rack-id other-label
label='operator label does not define membership'; check test "$rc" -eq 0
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
printf 'FANOUT_TOOL=pdsh\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='pdsh identity probe supported'; check test "$rc" -eq 0
label='pdsh transport explicitly selected'; check grep -q -- '-R ssh -w' "$PROBE_CALLS"
settings
printf 'FANOUT_COMMAND_TIMEOUT=0\n' >> "$SETTINGS_HOME/SETTINGS"
run
label='unbounded identity probe rejected'; check contains 'require positive fan-out'
settings
run --samples 7
label='sample override used in proposal'; check contains 'RACK_SAMPLES=7 sbatch'
run --membership-file ignored
label='membership-file interface removed'; check test "$rc" -eq 2
run --samples
label='missing option argument rejected'; check test "$rc" -eq 2
run --submit
label='submission option rejected'; check test "$rc" -eq 2
label='no mutating commands called'; check test ! -e "$FORBIDDEN_CALL"
label='no runtime directories or records created'; check test ! -e "$work/runtime-must-not-exist"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

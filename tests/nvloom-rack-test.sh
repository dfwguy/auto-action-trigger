#!/bin/bash
# Offline rack preflight and launch ordering; see docs/reference/jobs.md#nvloom-rack-preflight.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export BRINGUP_HOME="$repo" NODE_CONTAINER_DIR="$work" MPI_IFACE=eth0
export PATH="$work/bin:$PATH" RACK_TEST_WORK="$work"
touch "$work/nvloom-v2.0.0-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh"

cat > "$work/bin/nvidia-smi" <<'STUB'
#!/bin/bash
uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
[[ $RACK_CASE == query-failure && $SLURMD_NODENAME == node18 ]] && exit 1
[[ $RACK_CASE == empty && $SLURMD_NODENAME == node18 ]] && exit 0
if [[ $SLURMD_NODENAME == node18 ]]; then
    case $RACK_CASE in
        cross-rack) uuid=bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee ;;
        unavailable) uuid=N/A ;;
        zero) uuid=00000000-0000-0000-0000-000000000000 ;;
        blank) uuid='' ;;
        case) uuid=${uuid^^} ;;
    esac
fi
for gpu in 0 1 2 3; do
    if [[ $RACK_CASE == mixed-gpus && $SLURMD_NODENAME == node18 && $gpu == 3 ]]; then
        uuid=bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee
    fi
    printf '    ClusterUUID : %s\n' "$uuid"
done
STUB

cat > "$work/bin/srun" <<'STUB'
#!/bin/bash
while [[ ${1:-} == --* ]]; do shift; done
if [[ $1 == nvloom_cli ]]; then
    echo workload >> "$RACK_TEST_WORK/steps"
    exit 0
fi
echo probe >> "$RACK_TEST_WORK/steps"
rc=0
for ((i=1; i<=SLURM_JOB_NUM_NODES; i++)); do
    [[ $RACK_CASE == missing && $i == 18 ]] && continue
    printf -v SLURMD_NODENAME 'node%02d' "$i"
    [[ $RACK_CASE == duplicate && $i == 18 ]] && SLURMD_NODENAME=node01
    export SLURMD_NODENAME
    "$@" || rc=1
done
[[ $RACK_CASE == step-failure ]] && rc=1
exit "$rc"
STUB
chmod +x "$work/bin/"*

pass=0
fail=0
run_case() {
    local platform=$1 scenario=$2 nodes=$3 expected=$4 detail=$5 out steps
    export RACK_CASE=$scenario SLURM_JOB_NUM_NODES=$nodes
    : > "$work/steps"
    out=$(bash "$repo/jobs/$platform/nvloom-rack-nvlink.sbatch" 2>&1)
    steps=$(cat "$work/steps")
    if [[ $expected == pass && $steps == $'probe\nworkload' && $out == *PENDING* && $out == *"18 nodes share ClusterUUID="* ]] ||
       [[ $expected == fail && $steps == probe && $out == *FAIL* && $out == *"$detail"* ]]; then
        printf '  ok   %s: %s\n' "$platform" "$scenario"
        pass=$((pass + 1))
    else
        printf '  FAIL %s: %s (steps: %s)\n%s\n' "$platform" "$scenario" "$steps" "$out"
        fail=$((fail + 1))
    fi
}

for platform in nvl72 nvl72-spx; do
    run_case "$platform" same-rack 18 pass ''
    run_case "$platform" case 18 pass ''
    run_case "$platform" cross-rack 18 fail 'different rack'
    run_case "$platform" mixed-gpus 18 fail 'GPUs have different ClusterUUID'
    run_case "$platform" query-failure 18 fail 'cannot query'
    run_case "$platform" empty 18 fail 'no GPU ClusterUUID'
    run_case "$platform" unavailable 18 fail 'invalid GPU ClusterUUID'
    run_case "$platform" blank 18 fail 'no GPU ClusterUUID'
    run_case "$platform" zero 18 fail 'all zeros'
    run_case "$platform" duplicate 18 fail 'duplicate rack probe'
    run_case "$platform" missing 18 fail 'received 17'
    run_case "$platform" too-few 17 fail 'expected 18 allocated nodes'
    run_case "$platform" too-many 19 fail 'expected 18 allocated nodes'
    run_case "$platform" step-failure 18 fail 'membership could not be established'
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]

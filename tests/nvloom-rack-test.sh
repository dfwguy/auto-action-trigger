#!/bin/bash
# Offline rack/MPI preflight and launch ordering; see docs/reference/jobs.md#nvloom-rack-preflight.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export BRINGUP_HOME="$repo" NODE_CONTAINER_DIR="$work"
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

cat > "$work/bin/ip" <<'STUB'
#!/bin/bash
echo "$*" >> "$RACK_TEST_WORK/routes"
[[ $RACK_CASE == mpi-no-route ]] && exit 0
echo 'default via 192.0.2.1 dev eno1 proto dhcp'
[[ $RACK_CASE == mpi-route-failure || $RACK_CASE == mpi-override ]] && exit 1
echo 'default via 192.0.2.2 dev eno2 proto dhcp'
STUB

cat > "$work/bin/srun" <<'STUB'
#!/bin/bash
while [[ ${1:-} == --* ]]; do shift; done
if [[ $1 == nvloom_cli ]]; then
    echo workload >> "$RACK_TEST_WORK/steps"
    printf '%s %s\n' "${OMPI_MCA_btl_tcp_if_include:-}" "${OMPI_MCA_oob_tcp_if_include:-}" > "$RACK_TEST_WORK/mpi"
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
    local platform=$1 scenario=$2 nodes=$3 expected=$4 detail=$5 out steps mpi routes
    local expected_iface=eth0 expected_routes=''
    export RACK_CASE=$scenario SLURM_JOB_NUM_NODES=$nodes MPI_IFACE=eth0
    case $scenario in
        mpi-default|mpi-empty-override|mpi-no-route|mpi-route-failure)
            unset MPI_IFACE
            [[ $scenario == mpi-empty-override ]] && export MPI_IFACE=''
            expected_iface=eno1
            expected_routes='-4 route show default'
            ;;
        mpi-override) export MPI_IFACE=bond0; expected_iface=bond0 ;;
    esac
    : > "$work/steps"
    : > "$work/mpi"
    : > "$work/routes"
    out=$(
        unset OMPI_MCA_btl_tcp_if_include OMPI_MCA_oob_tcp_if_include
        bash "$repo/jobs/$platform/nvloom-rack-nvlink.sbatch" 2>&1
    )
    steps=$(cat "$work/steps")
    mpi=$(cat "$work/mpi")
    routes=$(cat "$work/routes")
    if [[ $routes == "$expected_routes" ]] && {
        [[ $expected == pass && $steps == $'probe\nworkload' && $out == *PENDING* &&
           $out == *"18 nodes share ClusterUUID="* && $out == *"MPI coordination interface: $expected_iface"* &&
           $mpi == "$expected_iface $expected_iface" ]] ||
        [[ $expected == fail && $steps == probe && $out == *FAIL* && $out == *"$detail"* && -z $mpi ]]
    }; then
        printf '  ok   %s: %s\n' "$platform" "$scenario"
        pass=$((pass + 1))
    else
        printf '  FAIL %s: %s (steps: %s; MPI: %s; routes: %s)\n%s\n' "$platform" "$scenario" "$steps" "$mpi" "$routes" "$out"
        fail=$((fail + 1))
    fi
}

for platform in nvl72 nvl72-spx; do
    run_case "$platform" same-rack 18 pass ''
    run_case "$platform" case 18 pass ''
    run_case "$platform" mpi-default 18 pass ''
    run_case "$platform" mpi-empty-override 18 pass ''
    run_case "$platform" mpi-override 18 pass ''
    run_case "$platform" mpi-no-route 18 fail 'no default-route interface found'
    run_case "$platform" mpi-route-failure 18 fail 'cannot query default-route interface'
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

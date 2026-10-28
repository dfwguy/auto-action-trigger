#!/bin/bash
set -o pipefail

home=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin"
pass=0; fail=0
ok() { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }

cat > "$work/bin/sudo" <<'EOF'
#!/bin/bash
[[ "$1" == -n ]] || exit 2
shift
exec "$@"
EOF
cat > "$work/bin/timeout" <<'EOF'
#!/bin/bash
[[ "$NIC_TIMEOUT" == yes && "$*" == *mlnx_qos* ]] && exit 124
exec /usr/bin/timeout "$@"
EOF
cat > "$work/bin/ethtool" <<'EOF'
#!/bin/bash
printf 'ethtool %s\n' "$*" >> "$NIC_CALLS"
[[ "$2" == "$NIC_FAIL_IFACE" ]] && { echo 'permission denied' >&2; exit 1; }
[[ "$NIC_EMPTY_TOOL" == ethtool ]] && exit 0
case "$1" in
    -k)
        echo "Features for $2 (MAC 02:00:00:00:00:01):"
        echo 'rx-checksumming: on'
        echo "tcp-segmentation-offload: ${NIC_OFFLOAD:-on}"
        echo 'MAC: 02:00:00:00:00:01'
        echo 'IP address: 192.0.2.1'
        ;;
    -g)
        echo "Ring parameters for $2:"
        echo 'Pre-set maximums:'
        echo 'RX: 8192'
        echo 'TX: 8192'
        echo 'Current hardware settings:'
        echo "RX: ${NIC_RING:-1024}"
        echo 'TX: 1024'
        ;;
    -l)
        echo "Channel parameters for $2:"
        echo 'Pre-set maximums:'
        echo 'Combined: 32'
        echo 'Current hardware settings:'
        echo 'Combined: 8'
        ;;
    -c)
        [[ "$NIC_COALESCE" == unsupported ]] && { echo 'Operation not supported' >&2; exit 1; }
        echo 'Adaptive RX: on TX: off'
        echo 'rx-usecs: 8'
        ;;
    -a)
        echo "Pause parameters for $2:"
        echo 'Autonegotiate: off'
        echo "RX: ${NIC_PAUSE:-on}"
        echo 'TX: on'
        ;;
    *) echo 'unexpected or mutating ethtool command' >&2; exit 2 ;;
esac
EOF
cat > "$work/bin/mlnx_qos" <<'EOF'
#!/bin/bash
printf 'mlnx_qos %s\n' "$*" >> "$NIC_CALLS"
[[ "$#" -eq 2 && "$1" == -i ]] || exit 2
[[ "$NIC_EMPTY_TOOL" == mlnx_qos ]] && exit 0
[[ "$NIC_QOS_FAIL" == yes ]] && { echo 'Operation not permitted' >&2; exit 1; }
echo "Device: $2 MAC 02:00:00:00:00:01"
echo 'DCBX mode: OS controlled'
echo "Priority trust state: ${NIC_TRUST:-dscp}"
echo 'dscp2prio mapping:'
if [[ "$NIC_REVERSE" == yes ]]; then
    echo '    prio:3 dscp:25,24,'
    echo '    prio:0 dscp:01,00,'
else
    echo '    prio:0 dscp:00,01,'
    echo "    prio:3 dscp:${NIC_DSCP:-24,25},"
fi
echo 'Cable len: 7'
echo "Receive buffer size (bytes): ${NIC_BUFFER:-131072},131072,0,0,0,0,0,0,max_buffer_size=262144"
if [[ "$NIC_NO_PFC" != yes ]]; then
    echo 'PFC configuration:'
    echo '    priority 0 1 2 3 4 5 6 7'
    echo "    enabled 0 0 0 ${NIC_PFC:-1} 0 0 0 0"
    echo '    buffer 0 0 0 1 0 0 0 0'
fi
echo 'tc: 0 ratelimit: unlimited, tsa: ets, bw: 50%'
echo '    priority: 0'
echo 'tc: 3 ratelimit: unlimited, tsa: ets, bw: 50%'
echo '    priority: 3'
EOF
cat > "$work/bin/dcb" <<'EOF'
#!/bin/bash
printf 'dcb %s\n' "$*" >> "$NIC_CALLS"
[[ "$#" -eq 4 && "$1 $2 $3" == 'pfc show dev' ]] || exit 2
echo 'pfc-cap 8 macsec-bypass off delay 0 '
echo "prio-pfc 0:off 1:off 2:off 3:${NIC_GENERIC_PFC:-off} 4:off 5:off 6:off 7:off"
echo "requests 0:${RANDOM} 1:0 2:0 3:0 4:0 5:0 6:0 7:0"
echo "indications 0:${RANDOM} 1:0 2:0 3:0 4:0 5:0 6:0 7:0"
EOF
chmod 755 "$work/bin/"*
export PATH="$work/bin:$PATH" NIC_CALLS="$work/calls"

make_net() {
    local root="$1" name="$2" driver="$3" type="${4:-1}" net
    net="$root/class/net/$name"
    mkdir -p "$net/device" "$root/drivers/$driver"
    ln -s "$root/drivers/$driver" "$net/device/driver"
    printf '%s\n' "$type" > "$net/type"
    echo 9000 > "$net/mtu"
    echo 1000 > "$net/tx_queue_len"
    printf '02:00:00:00:00:%02d\n' "$RANDOM" > "$net/address"
}
make_rdma() {
    local root="$1" name="$2" layer="$3" hca
    hca="$root/class/infiniband/$name"
    mkdir -p "$hca/ports/1"
    echo 32.42.1000 > "$hca/fw_ver"
    echo "$layer" > "$hca/ports/1/link_layer"
    echo '5: 4096' > "$hca/ports/1/active_mtu"
    echo "$RANDOM" > "$hca/node_guid"
}
for tree in a b; do
    root="$work/$tree"
    make_net "$root" "${tree}_cx" mlx5_core
    make_net "$root" "${tree}_bf3_p0" mlx5_core
    make_net "$root" "${tree}_bf3_p1" mlx5_core
    make_net "$root" "${tree}_mgmt" ixgbe
    make_net "$root" "${tree}_ib" mlx5_core 32
    mkdir -p "$root/class/net/lo" "$root/class/net/bond0" "$root/class/net/vlan1"
    make_rdma "$root" "${tree}_rdma_bf3" Ethernet
    make_rdma "$root" "${tree}_rdma_ib" InfiniBand
done

run() {
    BRINGUP_NIC_SYSFS_ROOT="$work/${1:-a}" \
        bash "$home/health-checks/nvl72/48-nic-settings.sh" 2> "$work/stderr"
}

if run a > "$work/baseline"; then ok 'complete collection succeeds'; else bad 'complete collection failed'; fi
if NIC_REVERSE=yes run b > "$work/other" && cmp -s "$work/baseline" "$work/other"; then
    ok 'renamed devices, different identifiers and reordered mappings match byte for byte'
else
    bad 'equivalent nodes differ'
    diff -u "$work/baseline" "$work/other"
fi
if grep -q '^interface_count=5$' "$work/baseline" &&
   [[ "$(grep -c '^mlnx_qos -i a_' "$NIC_CALLS")" == 3 ]] &&
   grep -q '^rdma_port_count=2$' "$work/baseline"; then
    ok 'all physical interfaces and RDMA ports, including both BF3 ports, are collected'
else bad 'interface coverage is incomplete or includes virtual interfaces'; fi
if grep -qE '02:00:00|192\.0\.2|a_bf3|b_bf3|node_guid|Features for|bus-info' "$work/baseline"; then
    bad 'identity leaked into comparison output'
else ok 'comparison contains no names, MACs, addresses or GUIDs'; fi
if grep -q 'pfc/pfc-cap 8 macsec-bypass off delay 0' "$work/baseline" &&
   grep -q 'qos/priority_buffer/3=1' "$work/baseline" &&
   grep -q 'qos/Receive buffer size (bytes):' "$work/baseline"; then
    ok 'PFC capabilities and receive-buffer settings are retained'
else bad 'PFC capabilities or receive-buffer settings were discarded'; fi

for setting in NIC_PFC=0 NIC_TRUST=pcp NIC_DSCP=26,27 NIC_OFFLOAD=off NIC_RING=2048 NIC_PAUSE=off NIC_GENERIC_PFC=on NIC_BUFFER=65536; do
    if env "$setting" BRINGUP_NIC_SYSFS_ROOT="$work/a" \
        bash "$home/health-checks/nvl72/48-nic-settings.sh" > "$work/drift" 2> "$work/stderr" &&
       ! cmp -s "$work/baseline" "$work/drift"; then
        ok "configuration drift detected: $setting"
    else bad "configuration drift was hidden: $setting"; fi
done

rm -rf -- "$work/b/class/net/b_bf3_p1"
run b > "$work/missing"
if ! cmp -s "$work/baseline" "$work/missing" && grep -q '^interface_count=4$' "$work/missing"; then
    ok 'a missing interface changes output even when its configuration was duplicated'
else bad 'missing duplicate interface was hidden'; fi

for setting in NIC_FAIL_IFACE=a_bf3_p0 NIC_EMPTY_TOOL=ethtool NIC_EMPTY_TOOL=mlnx_qos NIC_QOS_FAIL=yes NIC_NO_PFC=yes NIC_TIMEOUT=yes; do
    if env "$setting" BRINGUP_NIC_SYSFS_ROOT="$work/a" \
        bash "$home/health-checks/nvl72/48-nic-settings.sh" > "$work/error" 2> "$work/stderr"; then
        bad "inconclusive collection returned success: $setting"
    elif grep -q 'ERROR:' "$work/error" && ! cmp -s "$work/baseline" "$work/error"; then
        ok "inconclusive collection is explicit and differs from baseline: $setting"
    else bad "inconclusive collection was hidden: $setting"; fi
done
rm -f -- "$work/a/class/net/a_bf3_p0/mtu"
if run a > "$work/unreadable"; then bad 'an unreadable MTU passed';
elif grep -q 'mtu=ERROR: unreadable' "$work/unreadable"; then ok 'unreadable sysfs is explicit';
else bad 'unreadable sysfs was not explained'; fi
echo 9000 > "$work/a/class/net/a_bf3_p0/mtu"
mv "$work/bin/mlnx_qos" "$work/mlnx_qos.saved"
if run a > "$work/no-tool"; then bad 'missing QoS tool passed';
elif grep -q 'qos=ERROR: query unavailable' "$work/no-tool"; then ok 'missing QoS tool is explicit';
else bad 'missing QoS tool was hidden'; fi
mv "$work/mlnx_qos.saved" "$work/bin/mlnx_qos"
if NIC_COALESCE=unsupported run a > "$work/unsupported" && grep -q 'coalesce=unsupported' "$work/unsupported"; then
    ok 'unsupported optional query is distinct from a failed query'
else
    bad 'unsupported query was not recorded'
    cat "$work/stderr"
    grep -E 'ERROR|unsupported' "$work/unsupported"
fi
mkdir -p "$work/empty/class/net" "$work/empty/class/infiniband"
if run empty > "$work/empty-output"; then bad 'empty discovery passed';
elif grep -q 'ERROR: no physical NIC' "$work/empty-output"; then ok 'empty discovery is explicit';
else bad 'empty discovery was not explained'; fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

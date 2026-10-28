#!/bin/bash
# banner: ########INFO: Check NIC settings (Expected: all nodes the same, including BlueField)

export LC_ALL=C
set -o pipefail
sys="${BRINGUP_NIC_SYSFS_ROOT:-/sys}"
if ! work=$(mktemp -d "/tmp/bringup-nic-settings.${HOSTNAME:-node}.$$.XXXXXX"); then
    echo 'ERROR: cannot create NIC settings workspace'
    exit 1
fi
trap 'rm -rf -- "$work"' EXIT
failed=0

# Compare configuration multisets, retaining duplicates, without device identities.
# See docs/reference/health-checks.md#nic-settings.
query() {
    local section="$1" status
    shift
    reply=$(timeout 15s "$@" 2> "$work/stderr")
    status=$?
    if [[ "$status" -eq 0 && -n "$reply" ]]; then
        return 0
    fi
    if [[ "$status" -ne 0 && "$status" -ne 124 && "$section" != qos ]] &&
       grep -qiE 'Operation not supported|Not supported' "$work/stderr"; then
        printf '%s=unsupported\n' "$section" >> "$work/record"
    else
        printf '%s=ERROR: query unavailable\n' "$section" >> "$work/record"
        printf 'nic-settings: %s failed for %s (exit %s)\n' "$section" "$iface" "$status" >&2
        cat "$work/stderr" >&2
        failed=1
    fi
    return 1
}

number() {
    local key="$1" path="$2" value
    value=$(cat "$path" 2>/dev/null)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$work/record"
    else
        printf '%s=ERROR: unreadable\n' "$key" >> "$work/record"
        failed=1
    fi
}

ethtool_settings() {
    local section="$1" option="$2" settings
    if query "$section" sudo -n ethtool "$option" "$iface"; then
        settings=$(awk -v section="$section" '
            { gsub(/^[ \t]+|[ \t]+$/, ""); gsub(/[ \t]+/, " ") }
            /^Pre-set maximums:$/ { group="maximum/"; next }
            /^Current hardware settings:$/ { group="current/"; next }
            /^Adaptive RX: (on|off) TX: (on|off)$/ { print section "/" $0 }
            /^[A-Za-z0-9_ -]+: (on|off|n\/a|[0-9]+)( \[fixed\])?$/ {
                sub(/: /, "="); print section "/" group $0
            }
        ' <<< "$reply")
        if [[ -n "$settings" ]]; then
            printf '%s\n' "$settings" >> "$work/record"
        else
            printf '%s=ERROR: unrecognized output\n' "$section" >> "$work/record"
            failed=1
        fi
    fi
}

qos_settings() {
    local settings
    if query qos sudo -n mlnx_qos -i "$iface"; then
        settings=$(awk '
            { gsub(/^[ \t]+|[ \t]+$/, ""); gsub(/[ \t]+/, " ") }
            /^DCBX mode: (OS|Firmware|FW) controlled$/ { print "qos/" $0; dcbx=1 }
            /^Priority trust state: (pcp|dscp)$/ { print "qos/" $0; trust=1 }
            /^prio:[0-7] dscp:[0-9,]+$/ {
                split($1, prio, ":"); sub(/^.*dscp:/, "")
                n=split($0, values, ",")
                for (i=1; i<=n; i++) if (values[i]!="")
                    printf "qos/dscp/%02d=%s\n", values[i]+0, prio[2]
            }
            /^Cable len: [0-9]+$/ { print "qos/" $0 }
            /^PFC configuration:$/ { pfc=1; next }
            pfc && /^priority 0 1 2 3 4 5 6 7$/ { priorities=1; next }
            pfc && priorities && /^enabled( [01])+$/ && NF==9 {
                for (i=2; i<=9; i++) printf "qos/pfc/%d=%s\n", i-2, $i
                enabled=1; pfc=0
            }
            /^buffer( [0-7])+$/ && NF==9 {
                for (i=2; i<=9; i++) printf "qos/priority_buffer/%d=%s\n", i-2, $i
            }
            /^Receive buffer size \(bytes\): [0-9,]+(max_buffer_size=[0-9]+)?$/ {
                print "qos/" $0
            }
            /^(Receive buffer size|Receive buffer xon|Receive buffer xoff|Priority to buffer mapping): [0-9, ]+$/ {
                print "qos/" $0
            }
            /^tc: [0-7] ratelimit: (unlimited|[0-9.]+ Gbps), tsa: (vendor|strict|ets)(, bw: [0-9]+%)?$/ {
                tc=$2; sub(/^tc: [0-7] /, ""); print "qos/tc/" tc "/" $0; next
            }
            /^(priority:|up:) [0-7]( [0-7])*$/ && tc!="" {
                for (i=2; i<=NF; i++) print "qos/priority/" $i "=" tc
            }
            END { if (!dcbx || !trust || !enabled) exit 1 }
        ' <<< "$reply")
        if [[ "$?" -eq 0 ]]; then
            printf '%s\n' "$settings" >> "$work/record"
        else
            printf 'qos=ERROR: incomplete or unrecognized output\n' >> "$work/record"
            printf 'nic-settings: incomplete QoS output for %s\n' "$iface" >&2
            failed=1
        fi
    fi
}

pfc_settings() {
    local settings
    if query pfc sudo -n dcb pfc show dev "$iface"; then
        settings=$(awk '
            { gsub(/^[ \t]+|[ \t]+$/, ""); gsub(/[ \t]+/, " ") }
            /^pfc-cap [0-9]+ macsec-bypass (on|off) delay [0-9]+$/ { print "pfc/" $0 }
            /^prio-pfc( [0-7]:(on|off))+ *$/ {
                if (NF!=9) exit 1
                for (i=2; i<=NF; i++) print "pfc/" $i
                found=1
            }
            END { if (!found) exit 1 }
        ' <<< "$reply")
        if [[ "$?" -eq 0 ]]; then
            printf '%s\n' "$settings" >> "$work/record"
        else
            printf 'pfc=ERROR: incomplete or unrecognized output\n' >> "$work/record"
            failed=1
        fi
    fi
}

save_record() {
    sort "$work/record" | paste -sd '\t' >> "$work/$1"
}

show_records() {
    local kind="$1" count
    count=$(wc -l < "$work/$kind")
    printf '%s_count=%s\n' "$kind" "$count"
    sort "$work/$kind" | awk -F '\t' -v kind="$kind" '{
        printf "%s[%d]\n", kind, NR
        for (i=1; i<=NF; i++) print "  " $i
    }'
}

: > "$work/interface"
for net in "$sys"/class/net/*; do
    [[ -d "$net/device" ]] || continue
    iface="${net##*/}"
    : > "$work/record"
    driver=$(readlink -f "$net/device/driver")
    driver="${driver##*/}"
    if [[ -n "$driver" && -d "$net/device/driver" ]]; then
        printf 'driver=%s\n' "$driver" >> "$work/record"
    else
        printf 'driver=ERROR: unreadable\n' >> "$work/record"
        failed=1
    fi
    number type "$net/type"
    number mtu "$net/mtu"
    number tx_queue_len "$net/tx_queue_len"
    ethtool_settings offload -k
    ethtool_settings rings -g
    ethtool_settings channels -l
    ethtool_settings coalesce -c
    if [[ "$(cat "$net/type" 2>/dev/null)" == 1 ]]; then
        ethtool_settings pause -a
        case "$driver" in
            mlx5_core|mlx4_en) qos_settings ;;
            *) pfc_settings ;;
        esac
    else
        printf 'qos=not applicable: non-Ethernet interface\n' >> "$work/record"
    fi
    save_record interface
done
show_records interface
if [[ ! -s "$work/interface" ]]; then
    echo 'ERROR: no physical NIC interfaces discovered'
    failed=1
fi

: > "$work/rdma_port"
for hca in "$sys"/class/infiniband/*; do
    [[ -d "$hca" ]] || continue
    for port in "$hca"/ports/*; do
        [[ -d "$port" ]] || continue
        : > "$work/record"
        firmware=$(cat "$hca/fw_ver" 2>/dev/null)
        if [[ "$firmware" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
            printf 'firmware=%s\n' "$firmware" >> "$work/record"
        else
            printf 'firmware=ERROR: unreadable or unrecognized\n' >> "$work/record"
            failed=1
        fi
        layer=$(cat "$port/link_layer" 2>/dev/null)
        case "$layer" in
            Ethernet|InfiniBand) printf 'link_layer=%s\n' "$layer" >> "$work/record" ;;
            *) printf 'link_layer=ERROR: unreadable\n' >> "$work/record"; failed=1 ;;
        esac
        mtu=$(cat "$port/active_mtu" 2>/dev/null)
        if [[ "$mtu" =~ ^[1-5]:[[:space:]]+(256|512|1024|2048|4096)$ ]]; then
            printf 'active_mtu=%s\n' "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" >> "$work/record"
        else
            printf 'active_mtu=ERROR: unreadable or unrecognized\n' >> "$work/record"
            failed=1
        fi
        save_record rdma_port
    done
done
show_records rdma_port
exit "$failed"

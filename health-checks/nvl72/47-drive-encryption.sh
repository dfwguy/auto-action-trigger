#!/bin/bash
# banner: ########INFO: Check drive encryption (Expected: all nodes the same)
# See docs/reference/health-checks.md#drive-encryption.

export LC_ALL=C

if ! inventory=$(lsblk --list --noheadings --paths --raw --output NAME,TYPE,FSTYPE); then
    echo 'inventory: unknown (lsblk failed)'
    exit 1
fi
if [[ -z "$inventory" ]]; then
    echo 'inventory: unknown (lsblk returned no devices)'
    exit 1
fi

records=()
failed=0
devices=0
nvme_devices=0
have_cryptsetup=0
have_nvme=0
command -v cryptsetup >/dev/null 2>&1 && have_cryptsetup=1
command -v nvme >/dev/null 2>&1 && have_nvme=1

while read -r device type fstype extra; do
    [[ -n "$device" ]] || continue
    case "$type" in loop|rom) continue ;; esac
    case "$device" in /dev/ram[0-9]*|/dev/zram[0-9]*) continue ;; esac
    if [[ "$device" != /dev/* || ! "$type" =~ ^[a-zA-Z0-9_-]+$ ||
          ! "${fstype:-none}" =~ ^[a-zA-Z0-9_.+-]+$ || -n "$extra" ]]; then
        records+=('inventory: unknown (invalid lsblk record)')
        failed=1
        continue
    fi
    devices=$((devices + 1))

    luks=unknown
    if [[ "$have_cryptsetup" -eq 1 ]]; then
        diagnostic=$(timeout 15 sudo -n cryptsetup isLuks "$device" 2>&1)
        status=$?
        [[ -z "$diagnostic" ]] || printf '%s\n' "$diagnostic" >&2
        case "$status" in
            0) luks=yes ;;
            1) [[ -z "$diagnostic" && "$fstype" != crypto_LUKS ]] && luks=no ;;
        esac
    fi
    [[ "$luks" != unknown ]] || failed=1
    records+=("block type=$type fstype=${fstype:-none} luks=$luks")

    if [[ "$type" == disk && "$device" =~ ^/dev/nvme[0-9]+(c[0-9]+)?n[0-9]+$ ]]; then
        nvme_devices=$((nvme_devices + 1))
        security=unknown
        if [[ "$have_nvme" -eq 1 ]] &&
           controller=$(timeout 15 sudo -n nvme id-ctrl "$device"); then
            oacs=$(awk '$1 == "oacs" && $2 == ":" {print $3}' <<< "$controller")
            if [[ "$oacs" =~ ^0[xX][0-9a-fA-F]{1,4}$ ]]; then
                oacs=$((16#${oacs:2}))
            elif [[ "$oacs" =~ ^[0-9]{1,5}$ ]]; then
                oacs=$((10#$oacs))
            else
                oacs=-1
            fi
            if [[ "$oacs" -ge 0 && "$oacs" -le 65535 ]]; then
                security=no
                (( oacs & 1 )) && security=yes
            fi
        fi
        [[ "$security" != unknown ]] || failed=1
        records+=("nvme security_commands=$security")
    fi
done < <(sort -u <<< "$inventory")

if [[ "$devices" -eq 0 ]]; then
    echo 'inventory: unknown (no persistent block devices)'
    exit 1
fi
[[ "$have_cryptsetup" -eq 1 ]] || echo 'luks: unknown (cryptsetup missing)'
if [[ "$nvme_devices" -eq 0 ]]; then
    echo 'nvme: none'
elif [[ "$have_nvme" -eq 0 ]]; then
    echo 'nvme: unknown (nvme missing)'
fi
printf '%s\n' "${records[@]}" |
    awk '{count[$0]++} END {for (record in count) print record " count=" count[record]}' |
    sort
exit "$failed"

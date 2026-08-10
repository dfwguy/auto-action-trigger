#!/bin/bash
# banner: ########INFO: Node inventory (informational, never drains -- every value below is unique to this node)
# informational: yes
#
# Inventory, not a check: these values differ on every node by design, so they
# are recorded and never diffed against a baseline. Which facts belong here
# rather than in a check of their own is
# docs/explanation/node-inventory.md#uniform-is-a-check-unique-is-inventory,
# and the key list is docs/reference/node-inventory.md.

echo "collected.host: $(hostname -f 2>/dev/null || hostname)"
echo "collected.at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "collected.arch: $(uname -m)"
echo "collected.kernel: $(uname -r)"

## ── Node identity ────────────────────────────────────────────────────────
## A refused sudo prints to stderr and leaves stdout empty, so the fallback is
## the difference between "this node has no serial" and "nobody asked".
while read -r key dmi; do
  val=$(sudo -n dmidecode -s "$dmi" 2>/dev/null | grep -v '^#' | head -1)
  printf 'node.%s: %s\n' "$key" "${val:-not reported (dmidecode gave nothing)}"
done <<'KEYS'
manufacturer system-manufacturer
product system-product-name
serial system-serial-number
uuid system-uuid
KEYS

## ── GPUs ─────────────────────────────────────────────────────────────────
if command -v nvidia-smi >/dev/null 2>&1; then
  printf 'gpu.driver_version: %s\n' \
    "$(nvidia-smi --format=csv,noheader --query-gpu=driver_version | head -1)"
  nvidia-smi --format=csv,noheader \
    --query-gpu=index,uuid,serial,pci.bus_id,vbios_version |
  sed 's/, */,/g' |
  while IFS=, read -r i uuid serial bus vbios; do
    printf 'gpu.%s.uuid: %s\n'   "$i" "$uuid"
    printf 'gpu.%s.serial: %s\n' "$i" "$serial"
    printf 'gpu.%s.bus_id: %s\n' "$i" "$bus"
    printf 'gpu.%s.vbios: %s\n'  "$i" "$vbios"
  done
else
  echo 'gpu: nvidia-smi not found -- no GPU inventory from this node'
fi

## ── BMC ──────────────────────────────────────────────────────────────────
## The LAN channel is not fixed across vendors, so it is probed rather than
## assumed. Timed out for the same reason as 44-bmc-firmware.
bmc=""
for ch in 1 2 3 8; do
  bmc=$(timeout 10 sudo -n ipmitool lan print "$ch" 2>/dev/null)
  [ -n "$bmc" ] && break
  bmc=""
done
if [ -n "$bmc" ]; then
  printf 'bmc.channel: %s\n' "$ch"
  printf 'bmc.ip: %s\n'  "$(awk -F': *' '$1 ~ /^IP Address +$/  {print $2}'  <<<"$bmc" | head -1)"
  printf 'bmc.mac: %s\n' "$(awk -F': *' '$1 ~ /^MAC Address +$/ {print $2}' <<<"$bmc" | head -1)"
else
  echo 'bmc: ipmitool lan print said nothing on channels 1 2 3 8 -- BMC address not reported'
fi

## ── HCAs ─────────────────────────────────────────────────────────────────
if [ -d /sys/class/infiniband ]; then
  for d in /sys/class/infiniband/*; do
    [ -e "$d" ] || continue
    dev="${d##*/}"
    [ -e "$d/device" ] &&
      printf 'hca.%s.bdf: %s\n' "$dev" "$(basename "$(readlink -f "$d/device")")"
    printf 'hca.%s.node_guid: %s\n' "$dev" "$(cat "$d/node_guid" 2>/dev/null)"
    printf 'hca.%s.fw_ver: %s\n'    "$dev" "$(cat "$d/fw_ver" 2>/dev/null)"
    for p in "$d"/ports/*; do
      [ -e "$p" ] || continue
      printf 'hca.%s.port.%s.lid: %s\n' "$dev" "${p##*/}" "$(cat "$p/lid" 2>/dev/null)"
      printf 'hca.%s.port.%s.gid: %s\n' "$dev" "${p##*/}" "$(cat "$p/gids/0" 2>/dev/null)"
    done
  done
else
  echo 'hca: no /sys/class/infiniband -- no HCA inventory from this node'
fi

## ── Network interfaces ───────────────────────────────────────────────────
for n in /sys/class/net/*; do
  [ -e "$n" ] || continue
  i="${n##*/}"
  [ "$i" = lo ] && continue
  printf 'net.%s.mac: %s\n' "$i" "$(cat "$n/address" 2>/dev/null)"
  [ -e "$n/device" ] &&
    printf 'net.%s.bdf: %s\n' "$i" "$(basename "$(readlink -f "$n/device")")"
  ## Empty input gives paste no lines at all, so the default is applied here
  ## rather than with a sed the substitution would never reach.
  ipv4=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | paste -s -d,)
  printf 'net.%s.ipv4: %s\n' "$i" "${ipv4:-none}"
done

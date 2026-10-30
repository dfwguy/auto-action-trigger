#!/bin/bash
set -o pipefail

home=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/utils"
for tool in bash awk sort timeout grep cat; do
    ln -s "$(command -v "$tool")" "$work/utils/$tool"
done

real_lsblk=$(command -v lsblk)
cat > "$work/bin/lsblk" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$TEST_LSBLK_ARGS"
[[ " $* " == *' --output NAME,TYPE,FSTYPE '* ]] || exit 99
cat "$TEST_INVENTORY"
exit "${TEST_LSBLK_STATUS:-0}"
EOF
cat > "$work/bin/sudo" <<'EOF'
#!/bin/bash
[[ "$1" == -n ]] || exit 99
shift
printf '%s\n' "$*" >> "$TEST_CALLS"
if [[ "${TEST_SUDO_DENIED:-0}" == 1 ]]; then
    echo 'sudo: a password is required' >&2
    exit 1
fi
exec "$@"
EOF
cat > "$work/bin/cryptsetup" <<'EOF'
#!/bin/bash
[[ "$1" == isLuks && "$#" -eq 2 && "$2" == /dev/* ]] || exit 99
case "${TEST_CRYPT_MODE:-normal}" in
    denied) echo "Cannot read $2" >&2; exit 2 ;;
    diagnostic) echo "Cannot read $2" >&2; exit 1 ;;
    failed) exit 4 ;;
    timeout) exit 124 ;;
esac
grep -Fxq -- "$2" "$TEST_LUKS"
EOF
cat > "$work/bin/nvme" <<'EOF'
#!/bin/bash
[[ "$1" == id-ctrl && "$#" -eq 2 && "$2" == /dev/* ]] || exit 99
case "${TEST_NVME_MODE:-normal}" in
    failed) echo "Cannot identify $2" >&2; exit 1 ;;
    empty) exit 0 ;;
    malformed) echo 'oacs : invalid'; exit 0 ;;
esac
cat <<DATA
sn : serial-$TEST_NODE
subnqn : nqn.2014-08.org.nvmexpress:uuid:$TEST_NODE
mac : 02:00:00:00:00:11
address : 198.51.100.17
oacs : ${TEST_OACS:-0x17}
DATA
EOF
chmod 755 "$work/bin"/*

cat > "$work/node-a" <<'EOF'
/dev/nvme0n1 disk
/dev/nvme0n1p1 part vfat
/dev/nvme0n1p2 part crypto_LUKS
/dev/mapper/luks-aaaaaaaa crypt LVM2_member
/dev/mapper/vg-a-root lvm xfs
/dev/sda disk crypto_LUKS
/dev/mapper/data-aaaaaaaa crypt ext4
/dev/mapper/data-aaaaaaaa crypt ext4
/dev/loop0 loop squashfs
/dev/sr0 rom iso9660
/dev/zram0 disk swap
EOF
cat > "$work/luks-a" <<'EOF'
/dev/nvme0n1p2
/dev/sda
EOF
cat > "$work/node-b" <<'EOF'
/dev/mapper/data-bbbbbbbb crypt ext4
/dev/sdz disk crypto_LUKS
/dev/mapper/vg-b-root lvm xfs
/dev/nvme9n7p2 part crypto_LUKS
/dev/nvme9n7p1 part vfat
/dev/nvme9n7 disk
/dev/mapper/luks-bbbbbbbb crypt LVM2_member
EOF
cat > "$work/luks-b" <<'EOF'
/dev/nvme9n7p2
/dev/sdz
EOF
cat > "$work/expected" <<'EOF'
block type=crypt fstype=LVM2_member luks=no count=1
block type=crypt fstype=ext4 luks=no count=1
block type=disk fstype=crypto_LUKS luks=yes count=1
block type=disk fstype=none luks=no count=1
block type=lvm fstype=xfs luks=no count=1
block type=part fstype=crypto_LUKS luks=yes count=1
block type=part fstype=vfat luks=no count=1
nvme security_commands=yes count=1
EOF

export TEST_INVENTORY="$work/node-a" TEST_LUKS="$work/luks-a" TEST_NODE=aaaaaaaa
export TEST_CALLS="$work/calls" TEST_LSBLK_ARGS="$work/lsblk-args"
export TEST_CRYPT_MODE=normal TEST_NVME_MODE=normal TEST_OACS=0x17
export TEST_LSBLK_STATUS=0 TEST_SUDO_DENIED=0

run_check() {
    PATH="$work/bin:$work/utils" bash "$home/health-checks/nvl72/47-drive-encryption.sh" \
        > "$work/out" 2> "$work/err"
    status=$?
}
pass=0; fail=0
ok() { echo "ok: $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }
has() { grep -Fq -- "$1" "$work/out"; }
unknown() {
    run_check
    if [[ "$status" -ne 0 ]] && has "$2"; then ok "$1"; else bad "$1"; fi
}

run_check
if [[ "$status" -eq 0 ]] && diff -u "$work/expected" "$work/out"; then
    ok 'whole disks, partitions, LVM and active mappings have a sorted count summary'
else
    bad 'normal encrypted layout'
fi
if [[ "$(wc -l < "$work/calls")" -eq 8 ]]; then
    ok 'duplicate paths and ephemeral devices do not add probes'
else
    bad 'wrong number of read-only privileged probes'
fi
cp "$work/out" "$work/baseline"

## The stub accepts whatever the check asks for, so hand the real arguments to
## the real lsblk; only an option error counts, not a sandbox without sysfs.
mapfile -t lsblk_args < "$work/lsblk-args"
if [[ -z "$real_lsblk" ]]; then
    echo 'skip: lsblk is not installed here, so its arguments were not exercised'
elif err=$("$real_lsblk" "${lsblk_args[@]}" 2>&1 >/dev/null) ||
     ! grep -Eqi 'mutually exclusive|unrecognized option|invalid option|unknown column' <<< "$err"; then
    ok 'the installed lsblk accepts the arguments the check passes it'
else
    bad "the installed lsblk rejects the check's arguments: $err"
fi

TEST_INVENTORY="$work/node-b" TEST_LUKS="$work/luks-b" TEST_NODE=bbbbbbbb run_check
if [[ "$status" -eq 0 ]] && cmp -s "$work/baseline" "$work/out"; then
    ok 'renamed and reordered devices and controller identifiers match the baseline'
else
    bad 'equivalent nodes differ'
fi
if grep -Eq '/dev/|aaaaaaaa|bbbbbbbb|serial-|uuid:|02:00:|198\.51\.' "$work/out"; then
    bad 'node identifiers leaked to the comparison output'
else
    ok 'comparison output contains no device paths, UUIDs, serials, MACs or IPs'
fi

cat "$work/node-a" > "$work/extra-disk"
echo '/dev/sdb disk crypto_LUKS' >> "$work/extra-disk"
cat "$work/luks-a" > "$work/extra-luks"
echo /dev/sdb >> "$work/extra-luks"
TEST_INVENTORY="$work/extra-disk" TEST_LUKS="$work/extra-luks" run_check
if [[ "$status" -eq 0 ]] && has 'block type=disk fstype=crypto_LUKS luks=yes count=2' &&
   ! cmp -s "$work/baseline" "$work/out"; then
    ok 'an extra encrypted disk changes its count and the baseline comparison'
else
    bad 'encrypted device counts'
fi
grep -v '^/dev/mapper/data-' "$work/node-a" > "$work/locked"
TEST_INVENTORY="$work/locked" run_check
if [[ "$status" -eq 0 ]] && has 'block type=disk fstype=crypto_LUKS luks=yes count=1' &&
   ! has 'block type=crypt fstype=ext4' && ! cmp -s "$work/baseline" "$work/out"; then
    ok 'a locked volume retains its LUKS header and loses its active mapping'
else
    bad 'locked LUKS volume'
fi

sed 's/crypto_LUKS/ext4/g' "$work/node-a" > "$work/plaintext"
: > "$work/no-luks"
TEST_INVENTORY="$work/plaintext" TEST_LUKS="$work/no-luks" run_check
if [[ "$status" -eq 0 ]] && ! cmp -s "$work/baseline" "$work/out" &&
   has 'block type=part fstype=ext4 luks=no count=1'; then
    ok 'loss of LUKS encryption differs from the baseline'
else
    bad 'loss of LUKS encryption was hidden'
fi
for TEST_OACS in 0 0x16 0X0016 00022; do
    run_check
    if [[ "$status" -eq 0 ]] && has 'nvme security_commands=no count=1' &&
       has 'block type=part fstype=crypto_LUKS luks=yes count=1'; then
        ok "NVMe capability $TEST_OACS is independent of LUKS encryption"
    else
        bad "NVMe capability $TEST_OACS"
    fi
done
TEST_OACS=0x17

TEST_CRYPT_MODE=denied unknown 'cryptsetup permission failure is unknown' 'luks=unknown'
TEST_CRYPT_MODE=diagnostic unknown 'exit 1 with a diagnostic is unknown' 'luks=unknown'
TEST_CRYPT_MODE=failed unknown 'cryptsetup device failure is unknown' 'luks=unknown'
TEST_CRYPT_MODE=timeout unknown 'timed-out cryptsetup is unknown' 'luks=unknown'
TEST_SUDO_DENIED=1 unknown 'sudo refusal is unknown' 'luks=unknown'
TEST_LUKS="$work/no-luks" unknown 'a rejected LUKS signature contradicting lsblk is unknown' 'luks=unknown'
TEST_NVME_MODE=failed unknown 'NVMe query failure is unknown' 'nvme security_commands=unknown'
TEST_NVME_MODE=empty unknown 'empty successful NVMe query is unknown' 'nvme security_commands=unknown'
TEST_NVME_MODE=malformed unknown 'malformed NVMe capability is unknown' 'nvme security_commands=unknown'
TEST_LSBLK_STATUS=1 unknown 'failed inventory is unknown even with partial output' 'inventory: unknown'
: > "$work/empty"
TEST_INVENTORY="$work/empty" unknown 'empty successful inventory is unknown' 'inventory: unknown'
printf '/dev/loop0 loop squashfs\n' > "$work/ephemeral"
TEST_INVENTORY="$work/ephemeral" unknown 'ephemeral devices alone are inconclusive' 'inventory: unknown'
printf '/dev/sda disk ext4 surplus\n' > "$work/malformed"
TEST_INVENTORY="$work/malformed" unknown 'a malformed record is named, not reported as an empty inventory' 'invalid lsblk record'

mv "$work/bin/lsblk" "$work/lsblk"
unknown 'missing lsblk is explicit' 'inventory: unknown (lsblk failed)'
mv "$work/lsblk" "$work/bin/lsblk"
mv "$work/bin/nvme" "$work/nvme"
unknown 'missing nvme is explicit' 'nvme: unknown (nvme missing)'
mv "$work/nvme" "$work/bin/nvme"
mv "$work/bin/cryptsetup" "$work/cryptsetup"
unknown 'missing cryptsetup is explicit' 'luks: unknown (cryptsetup missing)'
mv "$work/cryptsetup" "$work/bin/cryptsetup"

printf '/dev/sda disk ext4\n' > "$work/sata"
TEST_INVENTORY="$work/sata" TEST_LUKS="$work/no-luks" run_check
if [[ "$status" -eq 0 ]] && has 'nvme: none' && has 'fstype=ext4 luks=no'; then
    ok 'SATA-only inventory distinguishes no NVMe from a failed probe'
else
    bad 'SATA-only inventory'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]

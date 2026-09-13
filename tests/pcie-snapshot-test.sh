#!/bin/bash
set -o pipefail

home=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

cat > "$work/lspci" <<'EOF'
#!/bin/bash
echo '0000:01:00.0 Ethernet controller [0200]: Mellanox [15b3:1234]'
EOF
chmod 755 "$work/lspci"
cat > "$work/snapshot" <<'EOF'
0000:01:00.0 Ethernet controller: Mellanox
    LnkCap: Port #0, Speed 32GT/s, Width x16
    LnkSta: Speed 32GT/s, Width x16
    ACSCtl: SrcValid-
    DevCtl: MaxReadReq 4096 bytes
EOF

run() {
    PATH="$work:$PATH" BRINGUP_PCIE_LSPCI_SNAPSHOT="$work/snapshot" \
        bash "$home/health-checks/nvl72/$1"
}

[[ -z "$(run 20-pcie-lnk-stat.sh)" ]] || { echo 'link check did not use the snapshot' >&2; exit 1; }
[[ "$(run 21-pcie-acs.sh)" == "1" ]] || { echo 'ACS check did not use the snapshot' >&2; exit 1; }
[[ "$(run 22-pcie-mrrs.sh)" =~ 1[[:space:]]+4096 ]] || { echo 'MRRS check did not use the snapshot' >&2; exit 1; }
echo 'all PCIe checks consumed one supplied lspci snapshot'

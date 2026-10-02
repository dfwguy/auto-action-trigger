# Node inventory (`logs/<node>/nodeinfo`)

What each node records about itself that is **unique to that node** — serials,
UUIDs, MACs, addresses. Written by `health-checks/$HEALTHCHECKS/45-nodeinfo.sh`
on the health-check cadence, and never diffed against a baseline. Why the split
falls where it does is
[explanation/node-inventory.md](../explanation/node-inventory.md).

The file is one `key: value` per line, in the order below. Every key is always
present: a fact a node cannot answer gets a line saying so, never a blank or a
missing key. See
[explanation/node-inventory.md#a-missing-value-still-gets-a-line](../explanation/node-inventory.md#a-missing-value-still-gets-a-line).

## Keys

| Key | Value | Source |
|-----|-------|--------|
| `collected.host` | FQDN of the node that produced this file | `hostname -f` |
| `collected.at` | UTC timestamp of this collection, ISO 8601 | `date -u` |
| `collected.arch` | `aarch64` or `x86_64` | `uname -m` |
| `collected.kernel` | Running kernel release | `uname -r` |
| `node.manufacturer` | System manufacturer | `dmidecode -s system-manufacturer` |
| `node.product` | System product name | `dmidecode -s system-product-name` |
| `node.serial` | **Node serial number** | `dmidecode -s system-serial-number` |
| `node.uuid` | System UUID | `dmidecode -s system-uuid` |
| `gpu.driver_version` | NVIDIA driver version (one per node, not per GPU) | `nvidia-smi` |
| `gpu.<n>.uuid` | **GPU UUID**, per GPU index | `nvidia-smi --query-gpu=uuid` |
| `gpu.<n>.serial` | **GPU serial number** | `nvidia-smi --query-gpu=serial` |
| `gpu.<n>.bus_id` | GPU PCIe bus ID | `nvidia-smi --query-gpu=pci.bus_id` |
| `gpu.<n>.vbios` | GPU VBIOS version — also gated by `nvidia-smi-ecc` | `nvidia-smi --query-gpu=vbios_version` |
| `bmc.channel` | IPMI LAN channel that answered | `ipmitool lan print` |
| `bmc.ip` | **BMC/iDRAC IP address** | `ipmitool lan print` |
| `bmc.mac` | **BMC/iDRAC MAC address** | `ipmitool lan print` |
| `hca.<dev>.bdf` | HCA PCIe BDF | `/sys/class/infiniband/<dev>/device` |
| `hca.<dev>.node_guid` | HCA node GUID | `/sys/class/infiniband/<dev>/node_guid` |
| `hca.<dev>.fw_ver` | HCA firmware — also gated by `ib-firmware` | `/sys/class/infiniband/<dev>/fw_ver` |
| `hca.<dev>.port.<n>.lid` | Port LID | `/sys/class/infiniband/<dev>/ports/<n>/lid` |
| `hca.<dev>.port.<n>.gid` | Port GID 0 | `/sys/class/infiniband/<dev>/ports/<n>/gids/0` |
| `net.<if>.mac` | **Interface MAC**, every interface but `lo` | `/sys/class/net/<if>/address` |
| `net.<if>.bdf` | **Interface PCIe BDF**, when the interface has one | `/sys/class/net/<if>/device` |
| `net.<if>.ipv4` | **Per-interface IPv4** with prefix, comma-separated, or `none` | `ip -4 -o addr show` |

`bmc.*` is the only group that can be absent as a group: when no IPMI channel
answers, the three keys are replaced by a single `bmc:` line naming what was
tried.  The same holds for `gpu:` and `hca:` on a node with neither.

## Reading it

One node:

```bash
less logs/<node>/nodeinfo
```

Across the fleet, from the head node — every node writes its own file to the
shared tree, so there is nothing to fan out for:

```bash
grep -H '^node.serial:' logs/*/nodeinfo
grep -H '^gpu.[0-9]*.serial:' logs/*/nodeinfo
```

Forcing a fresh collection on a node, rather than waiting for the cadence:

```bash
bash report_health.sh --refresh <node|nodelist>
```

Or run the collector directly on the nodes, which writes nothing and prints to
your terminal:

```bash
clush -w '<nodes>' 'bash $BRINGUP_HOME/health-checks/nvl72/45-nodeinfo.sh'
pdsh -R ssh -w '<nodes>' 'bash $BRINGUP_HOME/health-checks/nvl72/45-nodeinfo.sh'
```

## What is not here

Fabric-side facts — switch model, switch firmware, NVSwitch firmware, UFM
version — are not in this file and are not collectable from a compute node.
See [explanation/node-inventory.md#what-a-node-cannot-answer](../explanation/node-inventory.md#what-a-node-cannot-answer).

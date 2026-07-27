# Health checks (`actions/node_health.sh`, `health-checks/$HEALTHCHECKS/`)

Each check is one file: `health-checks/<set>/NN-<check>.sh`. `HEALTHCHECKS` in
`SETTINGS` names the set — `nvl72` ships, and everything below describes it.

`node_health.sh` is the runner. It executes each check in numeric order, writes
its output to `logs/<node>/<check>`, and diffs that against the baseline in
`valid-config/default/`. Any mismatch appends the check name to a `reason`
string. After all checks, it either sets the node `IDLE` (no failures) or `DOWN`
with the accumulated reason — but only when `DRAIN_AFTER_FAILED_HEALTH_CHECK`
is on. With it off, which is how it ships, the run is identical up to that
point and Slurm is simply left alone; see
[operations.md](operations.md#disabling-drains).

A `refresh` sentinel file in `logs/<node>/` must exist for the health script to
run — this is what prevents redundant re-checks on every monitoring cycle. Use
`node-health-refresh.sh` to set it.

`health-check.sh` summarizes what is failing across the whole cluster, grouped
by the *set* of checks a node failed rather than one section per check: nodes
that fail the same checks share one cause and one fix, so each group is one
incident however many nodes are in it. Drains that did not come from
`node_health.sh` are grouped by reason the same way, which keeps a powered-off
rack to one line. Node lists are compressed and wrapped, never truncated
mid-range, so they can be pasted straight into `node-health-refresh.sh`. Long
lists are elided by default; `--full` prints everything.

`sync-check.sh <node>` then diffs one node's output against the baseline for
each check named in its drain reason, which is usually the fastest way to see
why that node was taken down. One node per group is enough — the rest of the
group failed the same checks.

## The baseline is cluster-local

`valid-config/default` is a symlink to a copy of `logs/<node>` from a node
validated on **this** cluster. It is deliberately not in git
(`valid-config/.gitignore`), and it must not be: a committed `default` pointing
at a node name from another cluster gets copied over the live one on the next
tarball drop, and then every check on every node diffs against a file that isn't
there. The symptom is the whole cluster failing every check at once —
`health-check.sh` leads with a `WARNING: no baseline` banner when the link does
not resolve, because nothing below it is real. Set it with:

```bash
bash set-valid-default.sh <validated-node>
```

Whatever node you name becomes the definition of correct BIOS, OS, kernel
params, IMEX and NVLink for every other node, so validate it by hand first.

## Informational checks

Three checks carry `# informational: yes`: `node_health.sh` still runs them and
still writes `logs/<node>/<check>`, but never appends them to the reason, so
they cannot appear in a drain reason and cannot take a node down. They are
marked in the table below.

All three compare something that is per-rack, so they can never match a single
cluster-wide baseline — every node outside the baseline node's rack differs by
design, and enforcing them drains the fleet for its own topology:

| Check | Why it is per-rack |
|-------|--------------------|
| `nvidia-smi-cuuid` | ClusterUUID is shared within a rack, not across the cluster |
| `imex-node-config` | `nodes_config.cfg` lists that rack's IMEX domain members |
| `imex-status` | live domain membership matrix — per-rack, and it changes every time a node in the rack goes down, so any baseline for it goes stale |

Read them with `less logs/<node>/<check>` or `sync-check.sh --all <node>`.

This trades away automatic detection of a genuinely wrong ClusterUUID — a node
cabled into the wrong rack no longer drains for it. That is caught by the
benchmarks failing instead, which is the right place for it: as an enforced
check it fired on nearly every node in the cluster and told you nothing.

Node-local IMEX health is unaffected and still drains: `imex-channels`,
`imex-profile`, `imex-service` and `imex-readiness` all compare values that are
the same on every node in the cluster.

## The check file format

```bash
#!/bin/bash
# banner: ########INFO: Check BIOS
# informational: yes      (optional -- recorded, never contributes a reason)
# reason-detail: yes      (optional -- the check's output joins the reason)

grep -r . /sys/class/dmi/id/bios_* 2>/dev/null | cut -d'/' -f6- | sort | paste -s -d','
```

The check writes its result to stdout and nothing else; the runner adds the
banner, writes the file, and does the diff. stderr is not captured — it goes to
the BCM action output, so a tool's own complaint is visible without polluting
the file being diffed.

Three things are load-bearing:

- **The banner is reproduced verbatim** as the first line of the log file, and
  the baseline is a copy of that same log file. Change its text — including how
  many `#` it starts with — and every node fails that check against every
  baseline taken before the change.
- **The filename after the `NN-` prefix is the check name**, and that name is
  what the log file, the baseline file and the drain reason all use.
  Renumbering a check does not invalidate a baseline; renaming one does.
- **Each check runs in its own `bash`**, not sourced. One check that exits or
  sets a shell option cannot truncate the other 37.

To add a check: drop in a numbered file, run `node-health-refresh.sh` against
the baseline node, and re-run `set-valid-default.sh` so the baseline has an
entry for it. Without that second step the new check diffs against a missing
file and fails on every node.

To support another platform, copy the directory and delete what does not apply
— a check that is not there does not run, which is why this is a directory
rather than a pile of `uname` tests inside one script. Sets worth having:

| Set | Contents |
|-----|----------|
| `common` | The platform-agnostic subset — bios, os, kernel-params, cpu, memory, numa, dmesg, iface, enroot. The right starting point for a new platform. |
| `hgx-x86` | `common` plus GPU, NVLink, IB and PCIe, minus every IMEX and MNNVL check. Those are GB200/GB300-only and fail identically on every x86 HGX node, which is a whole-cluster drain for hardware that was never there — the same trap that keeps `nvsm` out of the default benchmark list. |
| `cpu-only` | Login, head and CPU compute nodes: `common` plus iface and bond, no GPU or NVLink. |
| `storage` | `common` plus IB, bond and mount checks, no GPU. |

## Reading the reason field

The reason is a list of check names, but it still cannot be split on whitespace
and used as filenames: `dmesg-xid` carries its own output into the reason
(`# reason-detail: yes`) and that output is free text. Reasons written before
checks moved into `health-checks/` also used hand-written headers that did not
match the log file — `Check BIOS` for `bios`, `enroot missing` for `enroot`.

`reason-map.sh` carries both cases and is shared by `health-check.sh` and
`sync-check.sh`. Anything else reading the reason field needs to go through it
too: match reason text against the known check names, and treat everything else
as free text a check dragged in.

| Check | What it validates |
|-------|-------------------|
| `bios` | BIOS version and settings |
| `os` | Kernel version, OS readiness |
| `kernel-params` | Kernel command-line parameters |
| `cpu-specs` | CPU architecture and topology |
| `cpu-freq` | CPU governor and per-socket frequency (must be >1800 MHz in performance mode) |
| `memory` | DIMM count and size |
| `numa-settings` | `kernel.numa_balancing=0`, THP=madvise |
| `numa` | NUMA node memory sizes |
| `nvidia-smi-ecc` | GPU ECC errors, remapped rows, power state |
| `nvlinks` | NVLink count and fabric state (72 links expected on GB/B series) |
| `nvlink-ber` | NVLink Bit Error Rate |
| `nvidia-smi-p2p-nvlink` | GPU P2P NVLink capability |
| `nvidia-smi-p2p-pcie` | GPU P2P PCIe capability |
| `nvidia-smi-cuuid` | GPU ClusterUUID (rack consistency check) — **informational** |
| `ib-status` | InfiniBand port state (all up and active) |
| `ib-down` | IB link recommendation flags via mlxlink |
| `ib-link` | IB link_downed and symbol_error counters |
| `ib-pkey` | IB partition key consistency |
| `ib-firmware` | IB HCA firmware versions |
| `pcie-lnk-stat` | PCIe LnkCap vs LnkSta speed/width mismatches |
| `pcie-acs` | PCIe ACS (Access Control Services) settings |
| `pcie-mrrs` | PCIe Max Read Request Size (expected 4096) |
| `iface` | Default gateway network interface |
| `bond` | Bond interface mode, speed, and member status |
| `imex-channels` | NVIDIA IMEX channel devices (GB series) |
| `imex-profile` | IMEX configuration |
| `imex-node-config` | IMEX nodes_config.cfg checksum — **informational** |
| `imex-service` | IMEX service status and ports |
| `imex-readiness` | IMEX ready state via nvidia-imex-ctl |
| `imex-status` | IMEX domain and node connection status — **informational** |
| `enroot` | Enroot runtime directory writability |
| `dmesg-nv_err` | NVIDIA driver NV_ERR_* errors |
| `dmesg-trace` | Kernel call traces |
| `dmesg-hw_err` | Hardware errors |
| `dmesg-xid` | NVIDIA Xid events |
| `dmesg-knvlink` | NVLink discovery failures |
| `dmesg-ipmi_ssif` | IPMI SSIF errors |
| `dmesg-mlx5_core` | Mellanox health issue errors |

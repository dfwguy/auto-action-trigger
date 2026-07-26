# Health checks (`actions/node_health.sh`)

The script runs each check, writes output to `logs/<node>/<check-name>`, and
diffs against the baseline in `valid-config/default/`. Any mismatch appends to a
`reason` string. After all checks, it either sets the node `IDLE` (no failures)
or `DOWN` with the accumulated reason.

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

The reason string is not simply a list of check names — `append_reason` writes
`Check BIOS` for the `bios` check, `cuuid` for `nvidia-smi-cuuid`, and
`dmesg-xid` carries its own output into the reason. `health-check.sh` matches
reason text against the known check names for that reason; anything reading the
reason field needs to do the same.

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
| `nvidia-smi-cuuid` | GPU ClusterUUID (rack consistency check) |
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
| `imex-node-config` | IMEX nodes_config.cfg checksum |
| `imex-service` | IMEX service status and ports |
| `imex-readiness` | IMEX ready state via nvidia-imex-ctl |
| `imex-status` | IMEX domain and node connection status |
| `enroot` | Enroot runtime directory writability |
| `dmesg-nv_err` | NVIDIA driver NV_ERR_* errors |
| `dmesg-trace` | Kernel call traces |
| `dmesg-hw_err` | Hardware errors |
| `dmesg-xid` | NVIDIA Xid events |
| `dmesg-knvlink` | NVLink discovery failures |
| `dmesg-ipmi_ssif` | IPMI SSIF errors |
| `dmesg-mlx5_core` | Mellanox health issue errors |

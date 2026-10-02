# Health checks (`health-checks/$HEALTHCHECKS/`)

Each check is one file: `health-checks/<set>/NN-<check>.sh`. `HEALTHCHECKS` in
`SETTINGS` names the set — `nvl72` ships, and everything below describes it.

`node_health.sh` is the runner. It executes each check in numeric order, writes
its output to `logs/<node>/<check>`, and diffs that against the baseline in
`valid-config/default/`. Any mismatch appends the check name to a `reason`
string. After all checks, it either resumes the node (no failures) or sets it
`DOWN` with the accumulated reason — but only when
`DRAIN_AFTER_FAILED_HEALTH_CHECK` is on. With it off, which is how it ships, the
run is identical up to that point and Slurm is simply left alone.

It fires on every agent cycle and re-checks on a cadence:
`HEALTH_INTERVAL_HOURS` after a clean run, `HEALTH_RETRY_INTERVAL_HOURS` after
one that found something. A `refresh` sentinel file in
`$HEALTH_LOG_DIR/<node>/` jumps the
queue — `report_health.sh --refresh` sets it. Every cycle writes what it decided
to `$HEALTH_LOG_DIR/<node>/health.log`, and `report_health.sh --explain` reports when each
node is next due. See
[health-cadence.md](../explanation/health-cadence.md).

## The check list

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
| `os-release` | Distribution ID and version (`uname -r` is `os`) |
| `ofed` | MLNX_OFED version, or the `mlx5_core` module version when `ofed_info` is absent |
| `hpcx` | HPC-X version, from the install directory under `/opt` |
| `fabricmanager` | Fabric Manager version and service state |
| `imex-version` | IMEX binary version (GB series) |
| `bmc-firmware` | BMC firmware revision, manufacturer and product |
| `nodeinfo` | Per-node inventory — serials, UUIDs, MACs, addresses — **informational** |
| `slurm-env` | `SLURM_*`, `SBATCH_*`, `SRUN_*`, `SALLOC_*` in the agent's environment, a login shell and `/etc/environment` — see [jobs.md#the-step-environment](jobs.md#the-step-environment) |

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
the agent's output, so a tool's own complaint is visible without polluting
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
  sets a shell option cannot truncate the other 45.

The metadata block is read from the first 10 lines and nowhere else —
`check_meta` in `node_health.sh` narrows to that range before matching, so a
check that greps the machine for the string `# banner:` cannot accidentally
declare one. Put the keys directly under the shebang. Every check carries a
`# banner:`; a check without one writes an empty first line into its log and
therefore differs from every baseline.

Checks are mode `644`, not `755`, and that is the same decision as running them
under `bash "$check_file"`: they are never executed directly, only handed to a
fresh interpreter by the runner. `755` would invite running one on its own,
which produces the check's stdout with no banner, no log file and no diff.

## Checks that need root

The cycle runs as `$JOB_USER`, so a check that needs privilege says `sudo -n`
inline — these files are read and run on their own, and a helper on `PATH`
would break that. Thirteen of the 46 do:

| Command | Checks |
|---|---|
| `dmesg` | `32-dmesg-nv_err`, `33-dmesg-trace`, `34-dmesg-hw_err`, `35-dmesg-xid`, `36-dmesg-knvlink`, `37-dmesg-ipmi_ssif`, `38-dmesg-mlx5_core` |
| `dmidecode` | `06-memory`, `45-nodeinfo` |
| `lspci -vvv` | `20-pcie-lnk-stat`, `21-pcie-acs`, `22-pcie-mrrs` |
| `ipmitool` | `37-dmesg-ipmi_ssif`, `44-bmc-firmware`, `45-nodeinfo` |

Neither `44-bmc-firmware` nor `45-nodeinfo` needs a new sudoers rule:
`dmidecode` and `ipmitool` were already granted for `06-memory` and
`37-dmesg-ipmi_ssif`. Both wrap their `ipmitool` calls in `timeout`, because a
wedged BMC blocks rather than failing and would hold the whole run — see
[explanation/node-inventory.md#a-missing-value-still-gets-a-line](../explanation/node-inventory.md#a-missing-value-still-gets-a-line).

`lspci` without `-vvv`, `nvidia-smi`, `ibstatus`, `systemctl is-active` and
every `/sys` and `/proc` read are unprivileged.

The rules for these come from `agent/sudoers.default`, installed by the site as
`/etc/sudoers.d/50-bringup`. `node_health.sh` discovers the list by grepping
`sudo -n <cmd>` out of the check set and preflights it before running anything,
so **a new check that needs a new command needs no change anywhere else** — and
a missing rule stops the whole run rather than producing output the baseline
will not match. Why that is fatal where every other gate here carries on is
[explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run](../explanation/running-unprivileged.md#a-lost-rule-must-stop-the-run).

## Informational checks

Four checks carry `# informational: yes`: `node_health.sh` still runs them and
still writes `logs/<node>/<check>`, but never appends them to the reason, so
they cannot appear in a drain reason and cannot take a node down.

Three of them compare something that is per-rack, so they can never match a
single cluster-wide baseline — every node outside the baseline node's rack
differs by design, and enforcing them drains the fleet for its own topology:

| Check | Why it is per-rack |
|-------|--------------------|
| `nvidia-smi-cuuid` | ClusterUUID is shared within a rack, not across the cluster |
| `imex-node-config` | `nodes_config.cfg` lists that rack's IMEX domain members |
| `imex-status` | live domain membership matrix — per-rack, and it changes every time a node in the rack goes down, so any baseline for it goes stale |

The fourth, `nodeinfo`, is not a comparison at all. It is this node's inventory
— serials, UUIDs, MACs, BMC address — every value of which is unique to the
node by design, so there is no baseline that could express a correct answer.
The flag gives it the one behaviour it needs: collected on the cadence,
written per node, never judged. The keys are
[reference/node-inventory.md](node-inventory.md) and the reason it is a check at
all rather than a script of its own is
[explanation/node-inventory.md#it-rides-the-health-check-runner](../explanation/node-inventory.md#it-rides-the-health-check-runner).

Read them with `less logs/<node>/<check>`, or across the fleet with
`report_health.sh --individual <check>`. Not `--diff --all`: that widens the diff
to every *gated* check, and `admin_set-baseline.sh` keeps the informational ones
out of the baseline, so there is nothing there to diff against — see
[explanation/node-inventory.md#it-is-not-a-baseline](../explanation/node-inventory.md#it-is-not-a-baseline).

This trades away automatic detection of a genuinely wrong ClusterUUID — a node
cabled into the wrong rack no longer drains for it. That is caught by the
benchmarks failing instead, which is the right place for it: as an enforced
check it fired on nearly every node in the cluster and told you nothing.

Node-local IMEX health is unaffected and still drains: `imex-channels`,
`imex-profile`, `imex-service` and `imex-readiness` all compare values that are
the same on every node in the cluster.

## The IB checks skip the nvswitch-attached ports

On B200/B300 four of the IB HCA ports are cabled to the nvswitch rather than to
the compute fabric. They are not the fabric links these checks are about, and
they do not present the state the checks expect, so `ib-down`, `ib-link` and
`ib-pkey` exclude them rather than reporting three failures per node forever.

The exclusion is built the same way in all three: `lspci` finds the InfiniBand
functions, and the result is turned into a run of `-e <bdf>.` words that
`grep -v` filters `/sys/class/infiniband` with. **Both shellcheck directives on
those lines are load-bearing.**

- **SC2046 — the word splitting is the point.** The substitution has to reach
  `grep -v` as separate arguments, one `-e <bdf>.` pair per nvswitch-connected
  function. Quoting it, which is what the warning asks for, collapses the run
  into a single pattern that matches nothing, and the check quietly stops
  excluding those ports. It still passes on a machine that has none, so the
  regression only shows up on real hardware — as every B200/B300 node draining
  for four ports that were never wrong.
- **SC2010 — `ls -l` is parsed, not just listed.** The long form prints the
  symlink targets, and those targets carry the PCI path the `awk` pulls the BDF
  out of; a glob returns the device names without them. The entries are
  kernel-generated sysfs device names, so the spaces-and-globs worry behind the
  warning does not apply here.

## Reading the reason field

The reason is a list of check names, but it still cannot be split on whitespace
and used as filenames: `dmesg-xid` carries its own output into the reason
(`# reason-detail: yes`) and that output is free text. Reasons written before
checks moved into `health-checks/` also used hand-written headers that did not
match the log file.

`reason-map.sh` carries both cases and is used by `report_health.sh`.
Anything else reading the reason field needs to go through it
too: rewrite the multi-word legacy names first, resolve the single-token
renames, then keep only tokens that name a check that exists — everything else
is free text a check dragged in.

| Reason text | Check |
|-------------|-------|
| `Check BIOS` | `bios` |
| `Check OS` | `os` |
| `enroot missing` | `enroot` |
| `cuuid` | `nvidia-smi-cuuid` |

Nothing emits these any more. `node_health.sh` writes the check name straight
into the reason, and the check name is the filename, so the two cannot diverge
again. They stay parseable because a node drained before the `health-checks/`
split keeps its old reason text in Slurm until something resumes it — which, for
a node nobody has touched, may be a long time. Deleting the rewrites turns those
nodes into a group of unrecognized operator drains in `report_health.sh`, which
is how a health drain stops being told apart from an operator's.

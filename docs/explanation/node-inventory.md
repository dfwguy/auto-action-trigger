# Why inventory is not a health check

The health checks answer one question: *does this node match the node we
validated?* Every one of them is a diff against `valid-config/default`, and the
whole apparatus — the baseline, the reason field, the drain — assumes the
correct answer is **the same on every node in the cluster**.

Inventory is the other kind of fact. A GPU serial number, a BMC address, an HCA
GUID: correct means *different on every node*, and there is no baseline that can
express that. Feeding one to the diff machinery produces a check that fails on
2,000 nodes out of 2,000, for ever, and says nothing.

Both kinds were wanted at once, which is where the split below comes from.

## Uniform is a check, unique is inventory

The test is not what the value describes, it is whether two healthy nodes should
agree on it:

| | Uniform across the fleet | Unique to the node |
|---|---|---|
| **Goes in** | a check of its own, diffed | `logs/<node>/nodeinfo` |
| **Wrong looks like** | one node drifting from the rest | nothing — it is a record, not a judgement |
| **GPU** | VBIOS version (`nvidia-smi-ecc`) | UUID, serial, bus ID |
| **Node** | BIOS version (`bios`), OS release (`os-release`), kernel (`os`) | serial, system UUID |
| **NIC / HCA** | firmware (`ib-firmware`), OFED (`ofed`) | device names, BDFs, MACs, per-port IPs, GUIDs, LIDs |
| **BMC** | firmware version (`bmc-firmware`) | IP, MAC |
| **Software** | Fabric Manager, IMEX, HPC-X versions | driver version, recorded for correlation only |

A few values appear on both sides on purpose. `vbios` and `hca.*.fw_ver` are
gated by a check *and* recorded in `nodeinfo`: the check is what notices drift,
and the inventory copy is what lets a reader tie a firmware level to the
specific card it came off without opening two files.

## It rides the health-check runner

`nodeinfo` is collected by `45-nodeinfo.sh`, a normal member of the check set
carrying `# informational: yes`. That flag already means *run it, write its log,
never let it contribute a drain reason* — see
[reference/health-checks.md#informational-checks](../reference/health-checks.md#informational-checks) —
which is precisely the behaviour inventory needs, so nothing new was written to
get it.

Riding the runner rather than being a script of its own buys three things that
would otherwise have to be built and then kept correct:

- **The cadence gate.** Collection happens every `HEALTH_INTERVAL_HOURS`, below
  the gate rather than above it. A collector on the agent cycle instead would be
  a per-node inventory sweep every two minutes, which on 2,000 nodes is the
  [fleet cost arithmetic](the-agent-and-the-watchdog.md#what-a-cycle-costs-the-share):
  work multiplied by the fleet, for an answer that changes when somebody
  replaces a card.
- **The sudo preflight.** `node_health.sh` discovers privileged commands by
  grepping `sudo -n <cmd>` out of the check set, so `dmidecode` and `ipmitool`
  in `45-nodeinfo.sh` are preflighted with everything else. Neither is a new
  grant: both were already in `agent/sudoers.default` for `06-memory` and
  `37-dmesg-ipmi_ssif`.
- **One writer per file.** Each node writes only its own `logs/<node>/nodeinfo`.
  A single fleet-wide inventory file would be 2,000 hosts writing one path on
  NFS, which is the failure described in
  [shared units](the-agent-and-the-watchdog.md#one-unit-for-both-roles): hosts
  taking each other's file and leaving a zero-length one behind. If a single file is wanted for something downstream, it is built
  on the head node by reading the 2,000, not written by them.

## It is not a baseline

`admin_set-baseline.sh` leaves `nodeinfo` out of the copy it promotes. Nothing
diffs the file, so including it would be inert rather than harmful — but
`valid-config/default` is the tree's statement of what correct looks like, and a
reader who opens it should not find one particular node's GPU serials and BMC
address sitting there presented as the answer.

It goes by the `# informational: yes` line rather than by the name `nodeinfo`,
because the argument is not about inventory: the three per-rack checks are
equally undiffed and equally not an answer, and a baseline that carries one
rack's `imex-status` presents a membership matrix that was true for one rack for
one minute. Reading the property is also what keeps the next informational check
from landing in the baseline unnoticed — a named file only covers the file that
was named. `report_health.sh` and `node_health.sh` read the same line from the
same place, so the three agree on which checks are gated without any of them
holding a list.

The same argument decides everything else in the node's log directory. The copy
is not the directory minus a list of things that are not checks; it is the gated
checks, by name, from `health_check_names` in `health-scan.sh` — the function
the reports judge with. The earlier form copied the whole directory and deleted
`refresh`, `.last-check`, `health.log` and `stderr.log`, and so promoted every
file nobody had listed: the agent's own `service.log`, written beside the check
output, arrived in the baseline as a "check" that matched no other node's log.
An allow-list cannot take in a file it was never told about.

One consequence worth expecting: the count `admin_set-baseline.sh` prints is now
the gated set, and matches the `N of M checks differ` that `--diff` prints. It
went down by the number of informational checks on the day this landed, without
a single check being removed.

## A missing value still gets a line

Every key is always present. A node with no GPUs prints `gpu:` and the reason,
not nothing; a refused `dmidecode` prints `not reported (dmidecode gave
nothing)`, not an empty value.

This applies the [inconclusive probe rule](architecture.md#no-answer-is-not-an-answer)
to inventory. The failure it guards against is specific: a refused `sudo`
writes to stderr, which the runner discards, and leaves stdout empty. `node.serial:` with
nothing after it is then indistinguishable from a chassis that genuinely reports
no serial, and the reader has no way to tell which they are looking at. Three
outcomes, not two: the value, a definite absence, or *the tool did not say* —
and the third names the tool.

The BMC is the sharpest case, and the only one with a timeout. A wedged BMC
answers neither way, and `ipmitool` against one blocks rather than failing. Both
`44-bmc-firmware` and the `bmc` section here run under `timeout`, because a
check that hangs holds the whole health run and, through it, the agent cycle —
see [work that outlives a cycle](containers.md#the-copy-is-its-own-unit). A BMC that
does not answer inside the timeout is reported as not having answered, which for
`44-bmc-firmware` also means that check differs from its baseline. That is
intended: a BMC nothing can reach is worth a line in a report.

## What a node cannot answer

Switch model, switch firmware, NVSwitch firmware and UFM version are not in
`nodeinfo`, and no amount of collecting on the compute node will put them there.
They are properties of the fabric, held by the subnet manager and the UFM host,
and a compute node can see its own link to the fabric but not the thing on the
other end of it.

They are left out rather than emitted as empty keys deliberately. A key present
and blank reads to anything consuming this file as *collected, and the answer is
nothing* — which would be a false statement about the switch rather than an
admission that the wrong host was asked. Collecting them is a head-node job
against the SM or UFM, and it is not this file.

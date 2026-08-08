# How a benchmark is judged

The gates live in `parsers/$PARSERS/verdict.sh`. That they are *derived* rather
than recorded is
[verdicts-and-the-cache.md](verdicts-and-the-cache.md); this page is about what
a good gate looks like, and the specific ways these ones have been got wrong.

## Where a pass is decided

An sbatch does **not** decide whether its own result is good. It reports only
whether it ran (`PENDING`) or could not (`FAIL`). `DONE` is derived by
`verdict.sh`, which is read by `launch_job.sh`, `status-check.sh` and
`daily-report.sh` every time they look at a result — it is never written to
disk.

That split exists because the alternative failed in a way nothing could recover
from. When each sbatch judged itself and wrote `DONE`, that verdict was frozen
at run time: `launch_job.sh` skips any job whose result file says `DONE`, so
tightening a gate could never re-examine the results it was written for. The
`-nonvlink` jobs ran entirely over TCP at 1.17 GB/s on 25 nodes, all reporting
`DONE`; the fix written to catch exactly that was correct, deployed, and
structurally unable to reach a single one of them. Clearing them by hand was the
only way out.

With the verdict derived, tightening a gate re-judges every result already on
disk on the next sweep. Result files ending in the old `DONE` marker are treated
as legacy and re-judged rather than trusted, which is what retires them.

**A gate should require positive evidence of a completed run**, not just the
absence of the word `error`. Every job here greps for something the tool only
prints when it actually ran — a results table, a health summary, a bandwidth
figure — because an empty output file otherwise reports a pass.

### `exit status:` says who decided a `FAIL`

Every job's parse section ends by recording its own exit status before the
marker. A non-zero there is the job's own verdict, with the cause somewhere in
the log above; `exit status: 0` under a `FAIL` means the workload ran clean and
the gate rejected the output, so the reason is in the status check rather than
in the file. The gate runs at status-check time and writes nothing back into the
result, so without this line the two are indistinguishable.

**A self-reported `FAIL` is never re-judged.** `DONE` is re-derived on every
read, but `FAIL` is taken at its word, because it means "the job could not run"
— the log is the diagnosis. It is the *status* that is frozen, not the
explanation: the gate still runs against the log to say why. That is what turns
fifty nodes reporting `dcgmi-r3: FAIL -- job reported FAIL` into fifty nodes
naming the subtest that failed.

The consequence to plan for: fixing a rule that wrongly condemned results leaves
every already-condemned result condemned. Those have to be re-run.

## Judge what the tool means, not what it says

The mirror image of the positive-evidence rule, and the more expensive one. A
failure string matched without regard to *where* it appears will match the
tool's own healthy output, and then the job cannot pass anywhere.

`nvbandwidth` did exactly this. MOP section 6.2 asks it to fail on "any `N/A`
where a peer transfer was expected", which the parse block implemented as
`grep -iE "N/A"` over the whole file. But every peer matrix prints `N/A` down
the diagonal, where a GPU would be talking to itself:

```
memcpy CE GPU(row) -> GPU(column) bandwidth (GB/s)
           0         1         2         3
 0       N/A    767.64    770.54    770.26
```

So the job failed every node with more than one GPU, on results that were
perfect. The fix is positional — `N/A` is expected on the diagonal of a
`GPU(row)` × `GPU(column)` matrix and nowhere else — and it lives in
`_v_gate_nvbandwidth`.

It failed closed and looked like a hardware finding: a node reporting
`nvbandwidth: FAIL` reads as a bad node, not as a bad grep.

Prefer the narrowest match that can only mean a fault: the string the tool
prints for the failure, matched case-sensitively where it is a fixed word, and
anchored where position carries the meaning. `_v_gate_nvsm` is currently the
loosest gate here — a case-insensitive sweep for `fail`/`error` over the whole
file — and it carries a comment saying so, because no healthy `nvsm show health`
output has been captured to narrow it against. That is the shape of an unpaid
debt in this file, not a pattern to copy.

## Gate on *how* the work ran, not only that it ran

`allreduce-forcesharp` exists for this reason, one level down. Both it and
`allreduce` set `NCCL_NVLS_ENABLE=1`, and on the NCCL 2.29 in this image that is
identical to the shipped default of 2: a node whose NVLS *allocation* fails
errors out, but a node with no NVLS *support at all* falls back to a GPU-side
algorithm without saying so. `allreduce` therefore passes on a node where SHARP
never ran, at whatever bandwidth the fallback happens to reach.

Adding `NCCL_ALGO=NVLS` removes the fallback: NVLS becomes the only algorithm
NCCL may pick, so an unsupported node fails in `ncclCommInitRank` instead. The
pair answers two different questions — `allreduce` asks whether the collective
works, `allreduce-forcesharp` asks whether the switch offload is the thing doing
it.

Its own question is settled before any bandwidth is measured: when it produces a
summary line at all, it ran the way `allreduce` is meant to. The floor is
therefore a second check rather than the point of the job, and it is set at 665
rather than the 683 `allreduce` uses — pinning the algorithm costs a little
bandwidth even where NVLS is what NCCL would have picked anyway, and the
unpinned floor fails healthy nodes for that difference. 665 is the bottom of the
band a healthy fleet occupies (665.0–673.3 out-of-place on ink50), which leaves
it very little room: a floor set anywhere inside that spread fails a different
set of nodes every cycle, and this one only just clears it.

`NCCL_ALGO` is the first line to suspect if it starts failing fleet-wide right
after an image change: which algorithms exist behind that name is a property of
the NCCL build, not of the fabric.

The same principle drives the `-nonvlink` pair. They exist to exercise the HCAs,
and NCCL will silently fall back to TCP over `bond0` when it finds no device —
producing a correct, complete, entirely worthless result. Both jobs force the
transport (`NCCL_NET=IB`), and the gate rejects any run whose per-channel
`via NET/...` lines name Socket.

## Judge the channels, never the plugin registration

Only the per-channel lines are evidence of where data went:

```
Channel 01/1 : 2[2] -> 3[3] [receive] via NET/Socket/0/Shared    <- TCP
Channel 00/0 : 0[0] -> 1[1] via P2P/MNNVL                        <- NVLink
```

These are **not**, in either direction:

```
NET/IB : No device found.
NET/Socket : Using [0]bond0:10.40.19.36<0>
Using network Socket
Using network IB
```

They name the net plugin NCCL registered, which it does whether or not the net
is ever used. A perfectly healthy single-node NVLink run initialises a net
plugin for potential inter-node use, finds no IB, falls back to Socket for that
role, logs all of the above, and then moves every byte over NVLink at 220 GB/s.

Both halves of this have now been got wrong once. `Using network IB` was
accepted as proof a run reached the HCAs when it proves nothing of the sort, and
then `Using network Socket` was rejected as proof a run had fallen to TCP —
failing a healthy 220.837 GB/s allreduce with 32 channels of `via P2P/MNNVL` as
`collective carried over TCP`. Both fixtures are in `tests/fixtures/`.

The NVLink-scope jobs forbid `via NET/` outright — any channel on the network,
Socket or IB, means the collective left NVLink. That is stated as a forbid
rather than as "require `via P2P`" deliberately: a forbid cannot false-fail a
legitimate path that happens to be named something the one healthy log inspected
did not contain.

## Host HCAs are not container HCAs

`jobs/nvl72/nccl-hca.sh` does two separate things, and conflating them is what
cost weeks. `nccl_hca_detect` runs on the **host** and chooses what to pin
`NCCL_IB_HCA` to. `NCCL_HCA_PROBE` runs **inside the container** and reports
what is visible there, via `ibv_devinfo` — the same libibverbs call NCCL makes.

Those answer different questions. enroot gives the container a fresh `/dev`, so
the host list can be complete and correct while the container sees nothing at
all. Checking by hand over `pdsh` puts you on the host and will show a healthy HCA
list no matter how broken the container's view is. Both lists are now printed
into every result file:

```
INFO: host /sys/class/infiniband: mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_bond_0
INFO: forcing collectives over HCAs: mlx5_0,mlx5_1,mlx5_2,mlx5_3
INFO: container NCCL_IB_HCA: mlx5_0,mlx5_1,mlx5_2,mlx5_3
INFO: container /dev/infiniband: rdma_cm uverbs0 uverbs1 uverbs2 uverbs3
INFO: container sees HCAs (via ibv_devinfo): mlx5_0 mlx5_1 mlx5_2 mlx5_3
```

The last line is a fixed format because `verdict.sh` gates on it: `(none)` fails
as `no HCA visible inside the container`.

The `ib` checks are ordered **by causation, not severity** — the first to fire
is the one whose reason gets reported. The chain runs: fresh `/dev` → container
cannot see the HCAs → `NET/IB : No device found.` → IB plugin fails to load →
fallback to Socket → every channel over `bond0`. Checking the last of those
first would report the whole cluster as `collective carried over TCP`, which is
true, and would send someone to look at the fabric instead of at a missing bind
mount. Keep new checks in causal order.

Reading a live node against this chain is
[how-to/diagnose-ib-visibility.md](../how-to/diagnose-ib-visibility.md).

## Floors are a property of the hardware

The five NCCL bandwidth floors are `VERDICT_MIN_PEAK_BW_*`, set in `SETTINGS`
rather than in the parser; the values are in
[reference/settings.md#benchmark-pass-floors](../reference/settings.md#benchmark-pass-floors).
Every other gate stays in `parsers/$PARSERS/verdict.sh`.

They are settings and not parser constants because all five are read off
known-good runs, and what counts as known-good is a property of the hardware,
not of the software. The `-nonvlink` pair — 93 and 83, measured on a 100 GB/s
compute plane — is the clearest case: a site on a different link speed has
different numbers, and should not have to edit a tracked file, or carry a patch
across a tarball drop, to say so.

Five settings rather than one because no two of them mean the same thing.
`allreduce` and `alltoall` are different collectives on the same NVLink fabric;
`allreduce-forcesharp` is `allreduce` with `NCCL_ALGO` pinned, which costs a
little bandwidth, so its floor sits below `allreduce`'s rather than tracking it;
and the `-nonvlink` pair crosses the compute-plane HCAs instead of NVLink.

All five read the same number: out-of-place busbw at the largest message size
actually run. That is also the figure `daily-report.sh` prints in those columns,
so a value in the report compares against the floor directly. The
`# Avg bus bandwidth` summary line is required to be present, as evidence the
run finished, but is **not** judged: it averages every message size and comes
out roughly half the largest-size figure on the same run, so a floor stated
against it could not be checked against anything an operator is looking at.

Both `-nonvlink` floors sit above every IB-scope result captured as a fixture —
the one that used to be `alltoall-nonvlink__good-ib` measures 32.35 and is now a
below-floor case. Read a full `daily-report.sh` before acting on drains from
these two jobs: **a handful of nodes under the floor is a fabric problem; every
node landing far below it is the floor being wrong**, and the first thing to
check is the compute plane's link speed.

These five are the ones to revisit as more platforms are learned; the eventual
answer for a platform that differs in more than a number is a parser directory
of its own (`nvl72-gb200`, `nvl72-gb300`) selected by `PARSERS`.

## What the tests hold

Run `tests/verdict-test.sh` after changing a gate. It checks
`parsers/nvl72/verdict.sh` against captured result files, including a real
socket run and a real healthy `nvbandwidth` run, and asserts the reason as well
as the verdict. When a gate rejects something it should not have, capture that
node's result file as a fixture *before* changing the rule — that is what stops
the next change to `verdict.sh` from quietly undoing this one.

**Coverage is uneven and worth knowing before you trust a gate.** `allreduce`,
`alltoall`, their `-nonvlink` pair, `dcgmi-r3`, `nvbandwidth` and `example` have
fixtures. The rest — `allreduce-forcesharp`, `nvloom`, `cublasmatmul`, `stream`,
`stressapptest`, `memtester`, `stress-ng`, `fio`, `ethr`, `hpl`, `llm-pretrain`,
`mnubergemm` and `nvsm` — do not, because no result file from this platform has
been captured for them; their rules were carried over from the parse blocks that
used to live in each sbatch and have never been run against real output. When
one of those jobs is first enabled at a site, capture its result file as a
fixture before trusting the verdict.

`tests/health-runner-test.sh` is the equivalent for the health side: it runs the
check loop out of `node_health.sh` against a synthetic check set and asserts
which mismatches reach the drain reason.

`tests/recover-test.sh` covers `slurm-recovery.sh` — the drain classification
and every gate in front of a resume — against stubbed `sinfo`, `scontrol`,
`squeue`, `systemctl` and `nvidia-smi`. Its operator cases matter most: a
mistake there resumes a node somebody took out of service, and that is invisible
from every direction afterwards.

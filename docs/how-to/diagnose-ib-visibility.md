# Diagnose IB visibility

```bash
bash check_ib.sh ink50-dh01-h20-36
```

For the two NCCL `-nonvlink` jobs, which need the HCAs and fail four different
ways that all look the same from a bandwidth number. Takes under a minute
instead of an hour of walltime.

It prints three sections in causal order:

1. **Host** — PCI devices, `/sys` and `/dev/infiniband`, what `nccl_hca_detect`
   picks after the bond/NVSwitch filter, and per-port state.
2. **Container** — the same image and mounts the job uses, `ibv_devinfo` (the
   call NCCL itself makes), ACTIVE-port count, and whether every device pinned
   in `NCCL_IB_HCA` on the host actually exists inside the container.
3. **NCCL init** — an 8-byte `allreduce_perf_mpi` with the job's environment and
   `NCCL_NET=IB`, filtered to the transport lines.

**The first section that is wrong is the cause; the rest are consequences.**

The case numbers it prints map to the reasons `report_job-status.sh` reports:

| Reported reason | Section that explains it |
| --- | --- |
| `no compute-plane HCA` (job self-reports `FAIL`) | host, case 1 |
| `no HCA visible inside the container` | container, case 2 |
| `no IB device visible to NCCL` | container, case 3 — ports not ACTIVE, or names pinned that the container cannot see |
| `collective carried over TCP` | NCCL init, case 4 |

Why the host's HCA list and the container's are separate questions at all is
[explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas](../explanation/judging-benchmarks.md#host-hcas-are-not-container-hcas).

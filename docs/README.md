# Documentation

The [root README](../README.md) covers prerequisites, first-time setup, and the
handful of commands a bringup needs day to day. Everything else lives here.

| Page | Covers |
|------|--------|
| [architecture.md](architecture.md) | How the three BCM triggers fit together, directory layout, runtime paths |
| [sequencer.md](sequencer.md) | `launch_job.sh` — sweep order, retry and drain rules, result-path ownership, Slurm permissions |
| [health-checks.md](health-checks.md) | `node_health.sh` — every check and what it validates |
| [benchmarks.md](benchmarks.md) | The `jobs/` catalog, test-plan coverage, what to set before enabling a job, adding a new one |
| [containers.md](containers.md) | `build_containers.sh` — why images are local, the two-pass source build, per-image notes |
| [nvsm.md](nvsm.md) | The sudoers grant and platform definition files `jobs/nvsm.sbatch` needs |
| [operations.md](operations.md) | Full operator command reference — status, node state, `NODRAIN`, trigger debugging |

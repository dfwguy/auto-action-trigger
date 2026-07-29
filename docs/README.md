# Documentation

The [root README](../README.md) covers prerequisites, first-time setup, and the
handful of commands a bringup needs day to day. Everything else lives here.

| Page | Covers |
|------|--------|
| [runners_guide.md](runners_guide.md) | Start here at a new site — where results land on disk, and the four tools that read them |
| [troubleshooting_the_system.md](troubleshooting_the_system.md) | Reading a failure back to the device that caused it — status words, verdict reasons and drain reasons, by component |
| [architecture.md](architecture.md) | How the three BCM triggers fit together, directory layout, runtime paths |
| [sequencer.md](sequencer.md) | `launch_job.sh` — sweep order, retry and drain rules, result-path ownership, Slurm permissions |
| [settings.md](settings.md) | `SETTINGS` / `SETTINGS.default` — every setting, what selects which directory, and the two drain switches |
| [health-checks.md](health-checks.md) | `node_health.sh` and `health-checks/$HEALTHCHECKS/` — every check, the check file format, adding a set for another platform |
| [benchmarks.md](benchmarks.md) | The `jobs/$JOBS/` catalog, test-plan coverage, what to set before enabling a job, adding a new one |
| [containers.md](containers.md) | `build_containers.sh` — why images are local, the two-pass source build, per-image notes |
| [nvsm.md](nvsm.md) | Why `jobs/nvl72/nvsm.sbatch` is DGX only and out of the default list; the sudoers grant and platform definition files it needs |
| [operations.md](operations.md) | Full operator command reference — status, node state, drains, trigger debugging |

# Documentation

Organised by what you are doing, following [Diátaxis](https://diataxis.fr/).
Four directories, four different jobs:

| If you are… | Go to |
|---|---|
| new to this and want it working | [tutorials/](#tutorials) |
| trying to get something specific done | [how-to/](#how-to-guides) |
| looking up a value, a flag, or what a line means | [reference/](#reference) |
| trying to understand why it works this way | [explanation/](#explanation) |

The [root README](../README.md) covers prerequisites and what has to be in place
before any of this.

## Tutorials

Learning-oriented. One guided path, no options, safe to follow on a live
cluster. Read these when you have *no* problem — they build the model the how-to
guides assume you already have.

| Page | Covers |
|------|--------|
| [first-bringup.md](tutorials/first-bringup.md) | Fresh tree → one node → one passing benchmark → reading its result. Start here at a new site |
| [understanding-the-triggers.md](tutorials/understanding-the-triggers.md) | Follow one BCM monitoring cycle end to end, and learn why "nothing happened" is written down |
| [reading-the-fleet.md](tutorials/reading-the-fleet.md) | The three status reports, what each one reads, why two can disagree, and the order to run them in |
| [troubleshooting-with-slurm.md](tutorials/troubleshooting-with-slurm.md) | Move between what Slurm knows about a node and what `results/` knows. Read-only throughout |

## How-to guides

Task-oriented, for someone who already knows the system.

**Running it**

| Page | Covers |
|------|--------|
| [run-a-job-by-hand.md](how-to/run-a-job-by-hand.md) | `launch_job.sh` flags, sweeping over `pdsh`, and `--test` for a job outside the list |
| [pause-and-resume.md](how-to/pause-and-resume.md) | The four pause switches, and `kill-jobs.sh` for emptying the queue now |
| [manage-drains.md](how-to/manage-drains.md) | Turning the two drain switches on, and reading what drained |
| [reset-results.md](how-to/reset-results.md) | `single-node-purge.sh`, and clearing the whole tree |
| [get-a-node-list.md](how-to/get-a-node-list.md) | Turn a report into a node list `pdsh`, `scancel` or `scontrol` will take |
| [find-outlier-nodes.md](how-to/find-outlier-nodes.md) | Find the slow node when every benchmark is passing |
| [export-a-report.md](how-to/export-a-report.md) | Getting `daily-report.sh` into a spreadsheet |

**Setting it up**

| Page | Covers |
|------|--------|
| [enable-a-benchmark.md](how-to/enable-a-benchmark.md) | Choosing a `BENCHMARKS` list, dependencies to check first, turning burn-in on |
| [add-a-benchmark.md](how-to/add-a-benchmark.md) | Adding a new `.sbatch` and its gate |
| [build-containers.md](how-to/build-containers.md) | `build_containers.sh`, the NGC login, cross-building for ARM |
| [add-a-health-check-set.md](how-to/add-a-health-check-set.md) | The baseline, adding a check, a set for another platform |
| [enable-llm-pretrain.md](how-to/enable-llm-pretrain.md) | `build_llmb.sh`, and filling in the solo training command |
| [enable-nvsm.md](how-to/enable-nvsm.md) | The sudoers grant and platform definition files NVSM needs (DGX only) |

**When something is wrong**

| Page | Covers |
|------|--------|
| [diagnose-nothing-running.md](how-to/diagnose-nothing-running.md) | `trigger-log.sh` then `trigger-debug.sh`, and reading the queue. Try this first |
| [diagnose-a-failed-node.md](how-to/diagnose-a-failed-node.md) | Reading a failure back to the device that caused it |
| [diagnose-ib-visibility.md](how-to/diagnose-ib-visibility.md) | `ib-visibility.sh`, for the two `-nonvlink` jobs |
| [estimate-when-a-job-will-start.md](how-to/estimate-when-a-job-will-start.md) | Your job is queued behind the sweep — how long, and what does not help. Written for anyone sharing the cluster |

## Reference

Lookup-oriented. Dry, complete, scannable.

| Page | Covers |
|------|--------|
| [settings.md](reference/settings.md) | Every key in `SETTINGS`, its default and what a valid value looks like |
| [scripts.md](reference/scripts.md) | Every operator script and what its output means |
| [jobs.md](reference/jobs.md) | The `jobs/$JOBS/` catalog, allocation header, time limits, queue priority |
| [health-checks.md](reference/health-checks.md) | All 38 checks, the check file format, the reason field |
| [trace-lines.md](reference/trace-lines.md) | Every line `trigger.log` can write |
| [reasons.md](reference/reasons.md) | Status words, verdict reasons and drain reasons, and what each implicates |
| [layout.md](reference/layout.md) | Directory tree, runtime paths, exec bits, Slurm permissions, what CI gates on |
| [llmb-run.md](reference/llmb-run.md) | The `llmb-run` tool itself — command surface and `cluster_config.yaml` |

## Explanation

Understanding-oriented. Why it is like this, and what it cost to find out.

| Page | Covers |
|------|--------|
| [architecture.md](explanation/architecture.md) | The three BCM triggers, *silence is the enemy*, registering with BCM, driving `cmsh` |
| [sequencing.md](explanation/sequencing.md) | One job at a time, the fleet cap, stale markers, retry and drain behaviour, what a pause is for |
| [verdicts-and-the-cache.md](explanation/verdicts-and-the-cache.md) | Why a verdict is derived and never stored, and what makes the cache safe |
| [judging-benchmarks.md](explanation/judging-benchmarks.md) | What a good gate looks like, and the two ways these have been got wrong |
| [drain-recovery.md](explanation/drain-recovery.md) | Which drains clear themselves, and how an operator's drain is protected |
| [containers.md](explanation/containers.md) | Why images are local, the caching layers, the two-pass source build |
| [llmb.md](explanation/llmb.md) | The two LLM jobs, why `llm-pretrain` is host-launched, running below characterised scale |
| [platform-sets.md](explanation/platform-sets.md) | Why `JOBS`, `HEALTHCHECKS` and `PARSERS` are three variables |
| [reading-the-whole-fleet.md](explanation/reading-the-whole-fleet.md) | Why `overall_report.sh` is an exception list, and where the reason for a failed prolog is kept |

## Adding to this

A new page goes in exactly one of the four directories, and the split that gets
got wrong is reference against explanation: a settings table is reference, *why
that default* is explanation. A page that needs to be both is two pages. See the
`docs/` section in `CLAUDE.md`, and run `./tests/doc-links-test.sh` after moving
or retitling anything.

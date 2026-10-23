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
before any of this. Contributors and AI assistants start with the shared
[instructions](../AGENTS.md) and [contributor workflow](how-to/contribute.md).

## Tutorials

Learning-oriented. One guided path, no options, safe to follow on a live
cluster. Read these when you have *no* problem — they build the model the how-to
guides assume you already have.

| Page | Covers |
|------|--------|
| [first-bringup.md](tutorials/first-bringup.md) | Fresh tree → one node → one passing benchmark → reading its result. Start here at a new site |
| [understanding-the-agent.md](tutorials/understanding-the-agent.md) | Follow one agent cycle end to end, watch the head node notice a node that stopped, and learn why "nothing happened" is written down |
| [reading-the-fleet.md](tutorials/reading-the-fleet.md) | The three status reports, what each one reads, why two can disagree, and the order to run them in |
| [reading-health-checks.md](tutorials/reading-health-checks.md) | The three `report_health.sh` views — `--drained`, `--summary`, `--individual` — and the refresh-and-retest loop that verifies a fix |
| [troubleshooting-with-slurm.md](tutorials/troubleshooting-with-slurm.md) | Move between what Slurm knows about a node and what `results/` knows. Read-only throughout |

## How-to guides

Task-oriented, for someone who already knows the system.

**Running it**

| Page | Covers |
|------|--------|
| [run-a-job-by-hand.md](how-to/run-a-job-by-hand.md) | `launch_job.sh` flags, sweeping a rack over `clush -w`, and `--test` for a job outside the list |
| [submit-a-job-file-directly.md](how-to/submit-a-job-file-directly.md) | Calling `sbatch` on a job file yourself: the site paths it needs on `--export`, and why `--test` is usually the answer instead |
| [arm-a-node.md](how-to/arm-a-node.md) | Installing the timer, checking a node stayed armed, and what to do when one will not |
| [install-abup.md](how-to/install-abup.md) | Symlinking `abup` onto `PATH`, the `BRINGUP_HOME` fallback for a detached copy, and what the "cannot find the tree" error means |
| [enable-lingering-before-installing.md](how-to/enable-lingering-before-installing.md) | Why `install-agent.sh` can enable lingering and still fail in the same run, and how to avoid it |
| [update-the-deployment.md](how-to/update-the-deployment.md) | Putting a new drop on the cluster: stop the fleet, `rsync` with the site's data excluded, confirm what landed, resume |
| [pause-and-resume.md](how-to/pause-and-resume.md) | The five run switches, and `admin_kill-jobs.sh` for emptying the queue now |
| [manage-drains.md](how-to/manage-drains.md) | Turning the two drain switches on, and reading what drained |
| [archive-and-clear-dmesg.md](how-to/archive-and-clear-dmesg.md) | The node that re-drains on `Prolog error` because its dmesg is full: saving the buffer, clearing it safely, and what clearing hides |
| [reset-results.md](how-to/reset-results.md) | `admin_purge-node-benchmarks.sh`, and clearing the whole tree |
| [get-a-node-list.md](how-to/get-a-node-list.md) | Turn a report into a node list `clush -w`, `scancel` or `scontrol` will take |
| [run-slurm-commands-remotely.md](how-to/run-slurm-commands-remotely.md) | What `squeue`/`scancel` need over `clush` or `pdsh` on a node with no login shell |
| [find-outlier-nodes.md](how-to/find-outlier-nodes.md) | Find the slow node when every benchmark is passing |
| [export-a-report.md](how-to/export-a-report.md) | Getting `report_benchmarks.sh` into a spreadsheet |

**Contributing**

| Page | Covers |
|------|--------|
| [contribute.md](how-to/contribute.md) | Shared AI instructions, memory migration, fresh-session verification and preparing a change |

**Setting it up**

| Page | Covers |
|------|--------|
| [enable-a-benchmark.md](how-to/enable-a-benchmark.md) | Choosing a `BENCHMARKS` list, dependencies to check first, turning burn-in on |
| [add-a-benchmark.md](how-to/add-a-benchmark.md) | Adding a new `.sbatch` and its gate |
| [build-containers.md](how-to/build-containers.md) | `build_containers.sh`, the NGC login, cross-building for ARM |
| [add-a-health-check-set.md](how-to/add-a-health-check-set.md) | The baseline, adding a check, a set for another platform |
| [enable-llm-pretrain.md](how-to/enable-llm-pretrain.md) | Stage the NeMo image and standalone Llama cache, then run both LLM jobs |
| [run-deepseek-v3-proxy.md](how-to/run-deepseek-v3-proxy.md) | Validate a standalone four-GPU DeepSeek proxy before automation rollout |
| [capture-an-sbatch-from-llmb-run.md](how-to/capture-an-sbatch-from-llmb-run.md) | Getting the batch script `llmb-run` generates out of a cluster, and what to keep from it |
| [enable-nvsm.md](how-to/enable-nvsm.md) | The sudoers grant and platform definition files NVSM needs (DGX only) |
| [configure-slurm-submission-limits.md](how-to/configure-slurm-submission-limits.md) | Set and verify the `MaxSubmitJobs` association limit and the controller enforcement it requires |

**When something is wrong**

| Page | Covers |
|------|--------|
| [diagnose-nothing-running.md](how-to/diagnose-nothing-running.md) | `check_trigger-log.sh` then `check_trigger-debug.sh`, the heartbeats, and reading the queue. Try this first |
| [see-what-fires-next.md](how-to/see-what-fires-next.md) | `check_next-run.sh` — when each node next tests or checks itself, and the three answers that are not times |
| [diagnose-a-failed-node.md](how-to/diagnose-a-failed-node.md) | Reading a failure back to the device that caused it |
| [diagnose-ib-visibility.md](how-to/diagnose-ib-visibility.md) | `check_ib.sh`, for the two `-nonvlink` jobs |
| [release-a-held-job.md](how-to/release-a-held-job.md) | A job held at priority 0 on `launch failed requeued held` that is not the framework's: whose it is, release against cancel-and-resubmit, and what a release cannot fix |
| [clear-an-unkillable-step.md](how-to/clear-an-unkillable-step.md) | A node held every cycle on GPU processes nothing will reap: confirming it, the evidence to capture, and getting it back |
| [estimate-when-a-job-will-start.md](how-to/estimate-when-a-job-will-start.md) | Your job is queued behind the sweep — how long, and what does not help. Written for anyone sharing the cluster |

## Reference

Lookup-oriented. Dry, complete, scannable.

| Page | Covers |
|------|--------|
| [contributing.md](reference/contributing.md) | Editing conventions, test selection and self-printing help headers |
| [settings.md](reference/settings.md) | Every key in `SETTINGS`, its default and what a valid value looks like |
| [scripts.md](reference/scripts.md) | Every operator script and what its output means |
| [jobs.md](reference/jobs.md) | The `jobs/$JOBS/` catalog, allocation header, time limits, queue priority |
| [health-checks.md](reference/health-checks.md) | All 46 checks, the check file format, the reason field |
| [node-inventory.md](reference/node-inventory.md) | Every key in `logs/<node>/nodeinfo` — serials, UUIDs, MACs, addresses — and where each comes from |
| [trace-lines.md](reference/trace-lines.md) | Every line `trigger.log` can write |
| [reasons.md](reference/reasons.md) | Status words, verdict reasons and drain reasons, and what each implicates |
| [layout.md](reference/layout.md) | Directory tree, runtime paths, exec bits, Slurm permissions, what CI gates on |
| [llmb-run.md](reference/llmb-run.md) | The `llmb-run` tool itself — command surface and `cluster_config.yaml` |

## Explanation

Understanding-oriented. Why it is like this, and what it cost to find out.

| Page | Covers |
|------|--------|
| [architecture.md](explanation/architecture.md) | How the pieces fit together, *silence is the enemy*, why every remote command is a `clush` or a `pdsh`, arming a node |
| [the-agent-and-the-watchdog.md](explanation/the-agent-and-the-watchdog.md) | What a heartbeat means, whose clock decides, which node states are armed, why the account lingers |
| [running-unprivileged.md](explanation/running-unprivileged.md) | What still needs root and what no longer does, the sudoers drop-in, why a lost rule stops the run |
| [sequencing.md](explanation/sequencing.md) | One job at a time, stale markers, retry and drain behaviour, what a pause is for |
| [the-fleet-snapshot.md](explanation/the-fleet-snapshot.md) | Why no compute node asks slurmctld anything, what the watchdog writes for each of them, and what a stale view obliges a node to do |
| [health-cadence.md](explanation/health-cadence.md) | Why the checks re-run on a timer, the stamp file, and why the golden baseline is a copy |
| [verdicts-and-the-cache.md](explanation/verdicts-and-the-cache.md) | Why a verdict is derived and never stored, and what makes the cache safe |
| [judging-benchmarks.md](explanation/judging-benchmarks.md) | What a good gate looks like, and the two ways these have been got wrong |
| [drain-recovery.md](explanation/drain-recovery.md) | Which drains clear themselves, and how an operator's drain is protected |
| [containers.md](explanation/containers.md) | Why images are local, the caching layers, the two-pass source build |
| [llmb.md](explanation/llmb.md) | The two LLM jobs, why `llm-pretrain` is host-launched, running below characterised scale |
| [burn-in-waveform.md](explanation/burn-in-waveform.md) | Why there are two burn-in jobs, what `--dual_mode` does, the two workload caps, and why a mistyped mnubergemm flag is silent |
| [platform-sets.md](explanation/platform-sets.md) | Why `JOBS`, `HEALTHCHECKS` and `PARSERS` are three variables |
| [reading-the-whole-fleet.md](explanation/reading-the-whole-fleet.md) | Why `report_overall.sh` is one grouped line per node, why `--details` is an exception list, and where the reason for a failed prolog is kept |
| [node-inventory.md](explanation/node-inventory.md) | Why unique-per-node facts cannot be health checks, what rides the check runner and what a node cannot answer |

## Adding to this

A new page goes in exactly one of the four directories, and the split that gets
got wrong is reference against explanation: a settings table is reference, *why
that default* is explanation. A page that needs to be both is two pages. See the
[documentation conventions](reference/contributing.md#documentation-structure),
and run `./tests/doc-links-test.sh` after moving or retitling anything.

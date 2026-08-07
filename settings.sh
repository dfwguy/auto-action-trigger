#!/bin/bash
#
# Loads the framework settings: SETTINGS if it exists, else SETTINGS.default,
# then backfills any key neither set. See docs/reference/settings.md.
#
# Set `home` (or SETTINGS_HOME) before sourcing. SETTINGS_FILE is left holding
# the path that was read, or empty if neither was found -- not fatal, since the
# defaults below are a complete working configuration on their own.

_settings_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"

SETTINGS_FILE=""
if [[ -f "$_settings_home/SETTINGS" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS"
elif [[ -f "$_settings_home/SETTINGS.default" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS.default"
fi

# shellcheck source=/dev/null
[[ -n "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"

## Defaults for anything the settings file did not set, matching what
## SETTINGS.default ships. What each key means is documented there.
: "${JOBS:=nvl72}"
: "${HEALTHCHECKS:=nvl72}"
: "${PARSERS:=nvl72}"
: "${BENCHMARKS:=dcgmi-r1 dcgmi-r3 nvbandwidth allreduce allreduce-forcesharp alltoall allreduce-nonvlink alltoall-nonvlink}"
## NCCL bandwidth floors, GB/s. Every other gate stays in the parser.
## See docs/reference/settings.md#benchmark-pass-floors.
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE:=683}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_FORCESHARP:=665}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL:=623}"
: "${VERDICT_MIN_PEAK_BW_ALLREDUCE_NONVLINK:=93}"
: "${VERDICT_MIN_PEAK_BW_ALLTOALL_NONVLINK:=83}"
## `=` not `:=`: an empty BURNIN means "no burn-in" and is a real answer.
## See docs/reference/settings.md#burn-in.
: "${RUN_BURNIN:=no}"
: "${BURNIN=mnubergemm}"
## `=` not `:=`: an empty CONTAINERS means "build nothing" and is a real
## answer. See docs/reference/settings.md#container-images.
: "${CONTAINERS=hpc-benchmarks nvbandwidth mnubergemm}"
## Pause and drain switches, all defaulting off so an empty or unreadable value
## carries on rather than stopping the fleet or draining it. See
## docs/reference/settings.md#pause-switches and docs/reference/settings.md#drains.
: "${PAUSE_JOBS:=no}"
: "${PAUSE_HEALTH_CHECKS:=no}"
: "${PAUSE_CONTAINER_COPY:=no}"
## Independent of PAUSE_JOBS: stopping the sweep and stopping drains being
## cleared are different decisions. See docs/reference/settings.md#pause-switches.
: "${PAUSE_RECOVERY:=no}"
: "${DRAIN_AFTER_FAILED_HEALTH_CHECK:=no}"
: "${DRAIN_AFTER_FAILED_BENCHMARK:=no}"
## Recovery of drains Slurm set itself. On by default, unlike the switches
## above: this one puts nodes back. RECOVER_REASONS is a case-insensitive ERE
## and must stay narrow -- it is the only discriminator left when an admin
## drains as root. See docs/explanation/drain-recovery.md.
: "${RECOVER_SLURM_DRAINS:=yes}"
: "${RECOVER_REASONS:=prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted|node was stopped|not responding|duplicate jobid|gres/gpu count|low socket|low cpus}"
: "${RECOVER_EMPTY_REASON:=yes}"
: "${RECOVER_SETTERS:=slurm root}"
: "${RECOVER_MAX_ATTEMPTS:=3}"
: "${RECOVER_WINDOW_HOURS:=24}"
## Both restarts ship on: the code only reaches them on a node that is up,
## drained and idle, and neither drain they clear can clear itself.
## See docs/explanation/drain-recovery.md#restarting-slurmd.
: "${RECOVER_RESTART_SLURMD:=yes}"
: "${RECOVER_REREGISTER:=yes}"
: "${RECOVER_SLURMD_WAIT:=30}"
## Nothing is judged mid-boot: every count below is a moving number until the
## node has finished coming up. 0 disables the uptime floor.
## See docs/explanation/drain-recovery.md#nothing-is-judged-mid-boot.
: "${RECOVER_MIN_UPTIME_SECS:=300}"
## Where the pre-job health check writes what it objected to -- the only place
## a rogueprocess drain names its process. Empty disables that check.
## See docs/explanation/drain-recovery.md#a-rogue-process-drain-names-its-process.
: "${RECOVER_PREJOB_LOGS:=/cm/local/apps/slurm/var/pre-post-job-logs/failed-pre-jobs}"
: "${RECOVER_PREJOB_SLACK_SECS:=900}"
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one --
## it means "one worker per core". See docs/reference/settings.md#reporting.
: "${SCAN_JOBS=}"
## Empty is a real answer here too: it means every node. See
## docs/reference/settings.md#restricting-which-nodes-run-jobs.
: "${NODE_FILTER=}"
## 0 is no cap. See docs/explanation/sequencing.md#the-fleet-wide-cap.
: "${MAX_QUEUED_JOBS:=500}"
: "${RETRY_INTERVAL_HOURS:=1}"
## On by default, and backfilled, so an existing site gets the ramp without
## editing anything. See docs/explanation/sequencing.md#backing-off-a-job-that-keeps-failing.
: "${RETRY_BACKOFF:=yes}"
: "${RETRY_BACKOFF_MAX_HOURS:=12}"
: "${MAX_JOB_HOURS:=7}"
## Experimental, and off: it is the one setting that cancels a job of ours that
## is working. See docs/explanation/sequencing.md#getting-out-of-the-way.
: "${GET_OUT_OF_THE_WAY:=no}"
: "${GET_OUT_OF_THE_WAY_AFTER_MINUTES:=5}"
: "${GET_OUT_OF_THE_WAY_POLL_MINUTES:=5}"
: "${DRAIN_WINDOW_MINUTES:=15}"
: "${INFLIGHT_GRACE_MINUTES:=30}"
: "${DRAIN_MARKER:=auto-retry}"
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one.
## Deliberately not exported -- launch_job.sh is the only reader and hands it
## to sbatch --export. See docs/reference/settings.md#extra-environment-for-every-job.
: "${JOB_ENV=}"
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/home/cmods/bringup}"
## `=` not `:=`, like CONTAINERS: empty means no llmb install.
## See docs/explanation/llmb.md#where-the-install-lives.
: "${LLMB_INSTALL=/home/cmods/llmb}"
: "${LLMB_REF=v26.06.01}"
## `=` not `:=`: empty means "search for it", which is how an install this tree
## did not build is adopted. llmb_check.py owns the search order.
## See docs/explanation/llmb.md#adopting-an-existing-install.
: "${LLMB_BIN=}"
: "${LLMB_CONFIG=}"
: "${LLMB_IMAGES=}"
: "${LLMB_HF=}"

## The only place these paths are built; no caller should rebuild them by hand.
## See docs/reference/settings.md#which-set-of-things-to-run.
##
## SC2034: read by the scripts that source this file, which shellcheck cannot
## see from here. Repeated because it covers only the next assignment.
# shellcheck disable=SC2034
JOBS_DIR="$_settings_home/jobs/$JOBS"
# shellcheck disable=SC2034
HEALTHCHECKS_DIR="$_settings_home/health-checks/$HEALTHCHECKS"
# shellcheck disable=SC2034
PARSERS_DIR="$_settings_home/parsers/$PARSERS"

## Read a yes/no setting. Anything not affirmative is off, including a typo and
## including empty. See docs/reference/settings.md#drains.
setting_enabled() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

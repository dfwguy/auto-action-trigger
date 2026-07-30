#!/bin/bash
#
# Loads the framework settings: SETTINGS if it exists, else SETTINGS.default,
# then backfills any key neither set. See docs/settings.md.
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
## `=` not `:=`: an empty BURNIN means "no burn-in" and is a real answer.
## See docs/settings.md#burn-in.
: "${RUN_BURNIN:=no}"
: "${BURNIN=mnubergemm}"
## `=` not `:=`: an empty CONTAINERS means "build nothing" and is a real
## answer. See docs/settings.md#container-images.
: "${CONTAINERS=hpc-benchmarks nvbandwidth mnubergemm}"
## Pause and drain switches, all defaulting off so an empty or unreadable value
## carries on rather than stopping the fleet or draining it. See
## docs/settings.md#pause-switches and docs/settings.md#drains.
: "${PAUSE_JOBS:=no}"
: "${PAUSE_HEALTH_CHECKS:=no}"
: "${PAUSE_CONTAINER_COPY:=no}"
: "${DRAIN_AFTER_FAILED_HEALTH_CHECK:=no}"
: "${DRAIN_AFTER_FAILED_BENCHMARK:=no}"
## Recovery of drains Slurm set itself. On by default, unlike the switches
## above: this one puts nodes back. RECOVER_REASONS is a case-insensitive ERE
## and must stay narrow -- it is the only discriminator left when an admin
## drains as root. See docs/settings.md#recovering-drains-slurm-set-itself.
: "${RECOVER_SLURM_DRAINS:=yes}"
: "${RECOVER_REASONS:=prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted|duplicate jobid|gres/gpu count}"
: "${RECOVER_EMPTY_REASON:=yes}"
: "${RECOVER_SETTERS:=slurm root}"
: "${RECOVER_MAX_ATTEMPTS:=3}"
: "${RECOVER_WINDOW_HOURS:=24}"
: "${RECOVER_RESTART_SLURMD:=no}"
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one --
## it means "one worker per core". See docs/settings.md#reporting.
: "${SCAN_JOBS=}"
: "${RETRY_INTERVAL_HOURS:=1}"
: "${MAX_JOB_HOURS:=7}"
: "${DRAIN_WINDOW_MINUTES:=15}"
: "${DRAIN_MARKER:=auto-retry}"
## `=` not `:=`, like CONTAINERS: empty is the shipped answer and a real one.
## Deliberately not exported -- launch_job.sh is the only reader and hands it
## to sbatch --export. See docs/settings.md#extra-environment-for-every-job.
: "${JOB_ENV=}"
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/home/cmods/bringup}"

## The only place these paths are built; no caller should rebuild them by hand.
## See docs/settings.md#which-set-of-things-to-run.
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
## including empty. See docs/settings.md#drains.
setting_enabled() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

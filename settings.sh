#!/bin/bash
#
# Loads the framework settings. Sourced by every script that needs to know
# which job set, health check set or parser set to use, and by the two BCM
# actions that need the drain switches.
#
# SETTINGS wins if it exists; otherwise SETTINGS.default is read. They are not
# layered on top of each other -- a site's SETTINGS is the whole answer, and
# SETTINGS.default is what is read when there isn't one. What IS layered is the
# defaults below: any key a settings file leaves unset is filled in here.
#
# That backfill is the part worth keeping. Without it, adding a key to
# SETTINGS.default silently breaks every site whose SETTINGS predates it -- the
# variable is empty, a path built from it points at a directory that does not
# exist, and the failure surfaces as "no benchmarks found" rather than as
# anything naming settings. With it, a SETTINGS only has to carry the lines the
# site actually changed.
#
# Usage: set `home` (or SETTINGS_HOME) first, then source this file.
#
#   home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$home/settings.sh"
#
# SETTINGS_FILE is left holding the path that was read, or empty if neither
# file was found. Callers that can usefully say so report it; nothing treats it
# as fatal, because the defaults below are a complete working configuration on
# their own.

_settings_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"

SETTINGS_FILE=""
if [[ -f "$_settings_home/SETTINGS" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS"
elif [[ -f "$_settings_home/SETTINGS.default" ]]; then
    SETTINGS_FILE="$_settings_home/SETTINGS.default"
fi

[[ -n "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"

## Defaults for anything the settings file did not set. These are the same
## values SETTINGS.default ships with -- the documentation for what each one
## means lives there, not here.
: "${JOBS:=nvl72}"
: "${HEALTHCHECKS:=nvl72}"
: "${PARSERS:=nvl72}"
: "${BENCHMARKS:=dcgm allreduce alltoall allreduce-nonvlink alltoall-nonvlink}"
## `=` rather than `:=`, unlike everything else here: an explicitly empty
## CONTAINERS is a real answer -- a site whose images are already in place, or
## which obtains them some other way, builds nothing. Backfilling that to
## hpc-benchmarks would quietly overrule it. Empty is only defaulted when the
## key is absent altogether.
: "${CONTAINERS=hpc-benchmarks}"
: "${DRAIN_AFTER_FAILED_HEALTH_CHECK:=no}"
: "${DRAIN_AFTER_FAILED_BENCHMARK:=no}"
: "${RETRY_INTERVAL_HOURS:=1}"
: "${MAX_JOB_HOURS:=6}"
: "${DRAIN_WINDOW_MINUTES:=15}"
: "${DRAIN_MARKER:=auto-retry}"
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/home/cmods/bringup}"

## Derived paths, so no caller has to remember which variable indexes which
## directory. Set here rather than in the settings file: they are a consequence
## of the choices above, not another thing to choose.
JOBS_DIR="$_settings_home/jobs/$JOBS"
HEALTHCHECKS_DIR="$_settings_home/health-checks/$HEALTHCHECKS"
PARSERS_DIR="$_settings_home/parsers/$PARSERS"

## Read a yes/no setting. Anything not affirmative is off, including a typo and
## including empty -- for two switches that decide whether nodes get taken out
## of service, an unreadable value has to mean "don't".
setting_enabled() {
    case "${1,,}" in
        yes|true|1|on) return 0 ;;
        *)             return 1 ;;
    esac
}

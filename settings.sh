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

# shellcheck source=/dev/null
[[ -n "$SETTINGS_FILE" ]] && source "$SETTINGS_FILE"

## Defaults for anything the settings file did not set. These are the same
## values SETTINGS.default ships with -- the documentation for what each one
## means lives there, not here.
: "${JOBS:=nvl72}"
: "${HEALTHCHECKS:=nvl72}"
: "${PARSERS:=nvl72}"
: "${BENCHMARKS:=dcgm nvbandwidth allreduce alltoall allreduce-nonvlink alltoall-nonvlink}"
## `=` rather than `:=`, for the same reason CONTAINERS uses it below: an
## explicitly empty BURNIN means "no burn-in phase" and is a real answer.
: "${RUN_BURNIN:=no}"
: "${BURNIN=mnubergemm}"
## `=` rather than `:=`, unlike everything else here: an explicitly empty
## CONTAINERS is a real answer -- a site whose images are already in place, or
## which obtains them some other way, builds nothing. Backfilling that to
## hpc-benchmarks would quietly overrule it. Empty is only defaulted when the
## key is absent altogether.
: "${CONTAINERS=hpc-benchmarks nvbandwidth mnubergemm}"
## Pause switches. Default `no` for the same reason the drain switches default
## off: a settings file written before these existed leaves them empty, and an
## empty value must mean "carry on as before" rather than "stop the fleet".
: "${PAUSE_JOBS:=no}"
: "${PAUSE_HEALTH_CHECKS:=no}"
: "${PAUSE_CONTAINER_COPY:=no}"
: "${DRAIN_AFTER_FAILED_HEALTH_CHECK:=no}"
: "${DRAIN_AFTER_FAILED_BENCHMARK:=no}"
## Recovery of drains Slurm set itself. `yes` by default, unlike the two drain
## switches above: those take nodes *out* of service and default off because an
## unreadable value must not do that, while this one puts them back and the
## cost of it being off is the silence the whole framework is built to avoid --
## a node drained for a failed prolog, testing nothing, forever.
##
## RECOVER_REASONS is an ERE, matched case-insensitively against the Slurm
## reason. Keep it narrow: it is the discriminator that has to hold when an
## admin drains as root, because Slurm's own drains land under root too.
: "${RECOVER_SLURM_DRAINS:=yes}"
: "${RECOVER_REASONS:=prolog|epilog|rogue ?process|batch job complete failure|Kill task failed|node unexpectedly rebooted}"
: "${RECOVER_EMPTY_REASON:=yes}"
: "${RECOVER_SETTERS:=slurm root}"
: "${RECOVER_MAX_ATTEMPTS:=3}"
: "${RECOVER_WINDOW_HOURS:=24}"
: "${RECOVER_RESTART_SLURMD:=no}"
: "${RETRY_INTERVAL_HOURS:=1}"
: "${MAX_JOB_HOURS:=7}"
: "${DRAIN_WINDOW_MINUTES:=15}"
: "${DRAIN_MARKER:=auto-retry}"
: "${JOB_USER:=cmods}"
: "${BRINGUP_HOME:=/home/cmods/bringup}"

## Derived paths, so no caller has to remember which variable indexes which
## directory. Set here rather than in the settings file: they are a consequence
## of the choices above, not another thing to choose.
##
## Nothing here reads them: they are handed to the scripts that source this
## file, which shellcheck cannot see from inside it. The directive is repeated
## because it only covers the one assignment that follows it.
# shellcheck disable=SC2034
JOBS_DIR="$_settings_home/jobs/$JOBS"
# shellcheck disable=SC2034
HEALTHCHECKS_DIR="$_settings_home/health-checks/$HEALTHCHECKS"
# shellcheck disable=SC2034
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

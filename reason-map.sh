#!/bin/bash
#
# Drain-reason -> check-name translation for report_health.sh, which uses it to
# tell a health drain from an operator's. Kept out of the script because the
# strings are historical rather than structural -- see the note below.
# See docs/reference/health-checks.md#reading-the-reason-field.
#
# Nothing new emits these strings -- they are pre-health-checks/ reason text
# that a node keeps in Slurm until something resumes it.

canonicalize_reason() {
    local r="$1"
    r="${r//Check BIOS/bios}"
    r="${r//Check OS/os}"
    r="${r//enroot missing/enroot}"
    printf '%s' "$r"
}

resolve_token() {
    case "$1" in
        cuuid) printf 'nvidia-smi-cuuid' ;;
        *)     printf '%s' "$1"          ;;
    esac
}

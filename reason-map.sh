#!/bin/bash
#
# Shared drain-reason -> check-name translation for health-check.sh and
# sync-check.sh; one copy, because the two drifting apart is what made
# sync-check.sh diff files called "Check", "BIOS" and "missing".
# See docs/health-checks.md#reading-the-reason-field.
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

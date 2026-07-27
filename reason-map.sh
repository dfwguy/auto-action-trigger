#!/bin/bash
#
# Shared translation from a Slurm drain reason to check names. Sourced by
# health-check.sh and sync-check.sh -- keep it in one place, because the two
# drifting apart is what made sync-check.sh try to diff files called "Check",
# "BIOS", "missing", "(no" and "output)".
#
# A drain reason still cannot be split on whitespace and used as filenames
# directly, for two reasons that survive the split into health-checks/:
#
#   dmesg-xid carries its own output into the reason (`# reason-detail: yes`),
#   and that output is free text which tokenizes into anything.
#
#   Reasons written before the split used hand-written headers that did not
#   match the log file the check produced:
#
#     "Check BIOS"     -> logs/<node>/bios            (two words)
#     "cuuid"          -> logs/<node>/nvidia-smi-cuuid
#     "enroot missing" -> logs/<node>/enroot          (two words)
#
# The rewrites below exist for that second case and are now legacy. Every check
# is a file in health-checks/<set>/, and node_health.sh writes the check name
# straight into the reason, so nothing new can produce these strings. They stay
# because a node drained before the upgrade keeps its old reason text in Slurm
# until something resumes it, and until then this is what parses it.
#
# So: rewrite the multi-word legacy names first, resolve the single-token
# renames, and then keep only tokens that name a check that actually exists --
# anything else is free text that a check dragged into the reason field.

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

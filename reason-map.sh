#!/bin/bash
#
# Shared translation from a Slurm drain reason to check names. Sourced by
# health-check.sh and sync-check.sh -- keep it in one place, because the two
# drifting apart is what made sync-check.sh try to diff files called "Check",
# "BIOS", "missing", "(no" and "output)".
#
# node_health.sh's append_reason does not always write the name of the log file
# the check produced:
#
#   append_reason "Check BIOS"    -> logs/<node>/bios          (two words)
#   append_reason "cuuid"         -> logs/<node>/nvidia-smi-cuuid
#   append_reason "enroot missing"-> logs/<node>/enroot         (two words)
#   append_reason "dmesg-xid " "${dmesg_xid_out}"
#                                 -> logs/<node>/dmesg-xid, plus the Xid output
#                                    itself, which is free text and tokenizes
#                                    into anything
#
# So a reason cannot be split on whitespace and used as filenames directly.
# Rewrite the multi-word names first, resolve the single-token renames, and then
# keep only tokens that name a check that actually exists -- anything else is
# free text that a check dragged into the reason field.

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

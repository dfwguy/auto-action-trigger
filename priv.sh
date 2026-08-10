#!/bin/bash
#
# Sourced. The one place a command that needs root is run from a cycle that is
# not root's. See docs/explanation/running-unprivileged.md.

## Resolved through the caller's PATH before sudo sees it: sudoers names full
## paths, and sudo's secure_path does not carry the Slurm client tools.
priv() {
    local path
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
        return
    fi
    path=$(command -v "$1" 2>/dev/null); [[ -n "$path" ]] || path="$1"
    shift
    sudo -n "$path" "$@"
}

## Reads are never privileged; only the updates are. PRIV_SCONTROL=direct is the
## site that gave JOB_USER AdminLevel=Operator instead.
## See docs/explanation/running-unprivileged.md#draining-without-root.
scontrol_update() {
    if [[ "${PRIV_SCONTROL,,}" == "direct" ]]; then
        scontrol update "$@"
    else
        priv scontrol update "$@"
    fi
}

## Names what sudo would refuse, in PRIV_MISSING, so a rule that is not there is
## reported once by name rather than as output that quietly stopped matching a
## baseline. A command that is not installed is not a sudo problem and is
## skipped. See docs/explanation/running-unprivileged.md#the-sudoers-drop-in.
PRIV_MISSING=""
priv_ready() {
    PRIV_MISSING=""
    [[ "$EUID" -eq 0 ]] && return 0
    if ! command -v sudo >/dev/null 2>&1; then
        PRIV_MISSING="sudo is not installed"
        return 1
    fi
    local cmd path
    for cmd in "$@"; do
        path=$(command -v "$cmd" 2>/dev/null) || continue
        [[ -n "$path" ]] || continue
        sudo -n -l -- "$path" >/dev/null 2>&1 || PRIV_MISSING+=" $path"
    done
    PRIV_MISSING="${PRIV_MISSING# }"
    [[ -z "$PRIV_MISSING" ]]
}

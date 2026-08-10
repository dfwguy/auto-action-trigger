#!/bin/bash
#
# Sourced. The one place this tree runs a command on more than one node.
# clush by preference, pdsh where clush is not installed, never a bare ssh.
# See docs/explanation/architecture.md#reaching-nodes-is-clush-or-pdsh.

## Which tool a cycle chose, and anything the caller should say about that
## choice. Resolved once.
FANOUT_CMD=""
FANOUT_WHY=""

## clush and pdsh both label output `<node>: <line>` and both take the same
## nodeset syntax, so a caller parses one format either way.
##
## SC2034: FANOUT_WHY is read by the callers, which shellcheck cannot see.
# shellcheck disable=SC2034
fanout_resolve() {
    [[ -n "$FANOUT_CMD" ]] && return 0
    local want="${FANOUT_TOOL:-auto}"
    case "${want,,}" in
        clush)
            command -v clush >/dev/null 2>&1 && { FANOUT_CMD=clush; return 0; }
            FANOUT_WHY="FANOUT_TOOL=clush but clush is not installed here" ;;
        pdsh)
            command -v pdsh >/dev/null 2>&1 && { FANOUT_CMD=pdsh; return 0; }
            FANOUT_WHY="FANOUT_TOOL=pdsh but pdsh is not installed here" ;;
        *)
            command -v clush >/dev/null 2>&1 && { FANOUT_CMD=clush; return 0; }
            command -v pdsh >/dev/null 2>&1 && {
                FANOUT_CMD=pdsh
                FANOUT_WHY="clush is not installed here, falling back to pdsh"
                return 0
            }
            FANOUT_WHY="neither clush nor pdsh is installed here" ;;
    esac
    return 1
}

## Both tools spell these the same: -t to connect, -u to run. Neither bounds the
## command by default, and a node whose NFS mount is hung answers the ssh and
## then never returns. See docs/explanation/architecture.md#a-fan-out-is-bounded.
fanout_timeouts() {
    local ct="${FANOUT_CONNECT_TIMEOUT:-10}" cmd="${FANOUT_COMMAND_TIMEOUT:-60}"
    [[ "$ct" =~ ^[0-9]+$ ]] || ct=10
    [[ "$cmd" =~ ^[0-9]+$ ]] || cmd=60
    printf '%s %s' "$ct" "$cmd"
}

## $1 nodeset, $2 the command. stderr is merged: a node that refused says so on
## it, and losing that leaves a failure with no text. `-R ssh` is spelled out
## because several packaged pdsh builds default to rsh.
fanout() {
    fanout_resolve || return 127
    local ct cmd
    read -r ct cmd < <(fanout_timeouts)
    if [[ "$FANOUT_CMD" == "clush" ]]; then
        clush -t "$ct" -u "$cmd" -w "$1" -- "$2" 2>&1
    else
        pdsh -t "$ct" -u "$cmd" -R ssh -w "$1" "$2" 2>&1
    fi
}

## The line to print for an operator to run by hand. Both forms, always: a site
## has one of the two installed and the reader should not have to translate.
fanout_example() {
    printf "  clush -w %s '%s'\n  pdsh -R ssh -w %s '%s'\n" "$1" "$2" "$1" "$2"
}

## ── Grouping `<node>: <line>` output ──────────────────────────────────────
##
## clubak is ClusterShell's dshbak and ships in the same package as clush, so a
## site that installed either tool family has the pair. Both read stdin and
## collapse identical lines under a compressed nodeset.
## See docs/reference/scripts.md#grouping-identical-rows.
BAK_CMD=()
bak_resolve() {
    [[ "${#BAK_CMD[@]}" -gt 0 ]] && return 0
    case "${FANOUT_TOOL:-auto}" in
        clush) command -v clubak >/dev/null 2>&1 && BAK_CMD=(clubak -b) ;;
        pdsh)  command -v dshbak >/dev/null 2>&1 && BAK_CMD=(dshbak -c) ;;
        *)     if command -v clubak >/dev/null 2>&1; then BAK_CMD=(clubak -b)
               elif command -v dshbak >/dev/null 2>&1; then BAK_CMD=(dshbak -c); fi ;;
    esac
    [[ "${#BAK_CMD[@]}" -gt 0 ]]
}

bak() {
    bak_resolve || return 127
    "${BAK_CMD[@]}"
}

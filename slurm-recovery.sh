#!/bin/bash
#
# Clearing drains that Slurm set itself. Sourced by actions/launch_job.sh and
# actions/node_health.sh -- never executed. The four reason classes, the three
# discriminators that protect an operator drain, the readiness checks and the
# rate limit are in docs/settings.md#recovering-drains-slurm-set-itself.
#
# Callers set before calling slurm_recover_node: RECOVER_ACCEPT (classes this
# caller may clear, space separated -- launch_job.sh "machine", node_health.sh
# after a clean run "machine health"), RECOVER_LOG, RECOVER_DRY_RUN, and
# optionally recover_log(). Everything else comes from settings.sh.

## Both callers already have somewhere their output goes; this library must not
## invent a third. No caller-supplied hook means stdout, for the test harness.
if ! declare -F recover_log >/dev/null 2>&1; then
    recover_log() { printf '%s\n' "$*"; }
fi

## Defaulted so that calling this with nothing set accepts no class and writes
## nothing, rather than surprising the caller.
: "${RECOVER_ACCEPT:=}"
: "${RECOVER_DRY_RUN:=0}"
: "${RECOVER_LOG:=}"

## Health reasons are lists of check names, not prose; the translation is
## reason-map.sh, shared rather than copied (docs/health-checks.md#reading-the-reason-field).
## Not re-sourced if a caller already did.
if ! declare -F canonicalize_reason >/dev/null 2>&1; then
    _recover_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"
    [[ -f "$_recover_home/reason-map.sh" ]] && source "$_recover_home/reason-map.sh"
fi

## sinfo reports "none", "(null)" or an empty string depending on release; all
## three mean the bare drain that RECOVER_EMPTY_REASON governs.
recover_reason_empty() {
    local r="$1"
    r="${r#"${r%%[![:space:]]*}"}"
    r="${r%"${r##*[![:space:]]}"}"
    [[ -z "$r" || "$r" == "none" || "$r" == "(null)" ]]
}

## A reason node_health.sh wrote is identified by its check names, not a marker.
## One matching token is enough -- dmesg-xid drags free text into the reason, so
## a health reason is not required to be *only* check names.
recover_reason_is_health() {
    local reason="$1" raw name
    [[ -d "$HEALTHCHECKS_DIR" ]] || return 1
    declare -F canonicalize_reason >/dev/null 2>&1 || return 1
    for raw in $(canonicalize_reason "$reason"); do
        name=$(resolve_token "$raw")
        [[ -n "$name" ]] || continue
        compgen -G "$HEALTHCHECKS_DIR/[0-9]*-$name.sh" >/dev/null 2>&1 && return 0
    done
    return 1
}

## marker | health | machine | operator, most specific first: a benchmark drain
## whose text happens to contain "prolog" must not be read as Slurm's.
## docs/settings.md#how-an-operators-drain-is-protected
recover_classify() {
    local reason="$1" setter="$2"
    if [[ -n "$DRAIN_MARKER" && "$reason" == *"$DRAIN_MARKER"* ]]; then
        printf 'marker'; return 0
    fi
    if recover_reason_is_health "$reason"; then
        printf 'health'; return 0
    fi
    ## Setter before pattern: an operator who typed something machine-looking is
    ## still classified by who they are.
    if [[ -n "$setter" && "$setter" != "none" ]] && \
       [[ " ${RECOVER_SETTERS} " != *" $setter "* ]]; then
        printf 'operator'; return 0
    fi
    if recover_reason_empty "$reason"; then
        ## Separately opt-out: this is the one class recognised by an absence
        ## rather than by something written down.
        if setting_enabled "$RECOVER_EMPTY_REASON"; then
            printf 'machine'
        else
            printf 'operator'
        fi
        return 0
    fi
    if [[ -n "$RECOVER_REASONS" ]] && grep -qEi -- "$RECOVER_REASONS" <<<"$reason"; then
        printf 'machine'; return 0
    fi
    printf 'operator'
}

## Discriminator 3. maint, reserved, planned and fail are somebody's deliberate
## arrangement, not drains to clear. sinfo's trailing `*` (slurmd not answering)
## is kept, not stripped: it decides whether a resume can work at all.
recover_state_recoverable() {
    case "${1,,}" in
        *maint*|*reserv*|*planned*|*fail*) return 1 ;;
        *drain*|*down*)                    return 0 ;;
        *)                                 return 1 ;;
    esac
}

## Has the condition actually cleared? Deliberately narrow -- a check that
## cannot be satisfied is a node that never comes back. Sets RECOVER_NOT_READY
## to why. docs/settings.md#why-a-resume-is-not-enough-on-its-own
RECOVER_NOT_READY=""
recover_node_ready() {
    local node="$1" pids jobs
    RECOVER_NOT_READY=""

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet slurmd 2>/dev/null; then
            if ! setting_enabled "$RECOVER_RESTART_SLURMD"; then
                RECOVER_NOT_READY="slurmd is not active on $node and RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD -- 'systemctl restart slurmd' on the node, or set it to yes"
                return 1
            fi
            if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
                recover_log "WOULD RESTART slurmd on $node (RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD)"
            else
                recover_log "restarting slurmd on $node (RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD)"
                systemctl restart slurmd 2>/dev/null
                if ! systemctl is-active --quiet slurmd 2>/dev/null; then
                    RECOVER_NOT_READY="slurmd did not come back after a restart -- resuming would only put $node back into down*"
                    return 1
                fi
            fi
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -v '^$' | tr '\n' ' ')
        if [[ -n "$pids" ]]; then
            RECOVER_NOT_READY="compute processes still on the GPUs (pids ${pids% })"
            return 1
        fi
    fi

    if command -v squeue >/dev/null 2>&1; then
        jobs=$(squeue -h -w "$node" -o '%i' 2>/dev/null | grep -c .)
        if [[ "$jobs" -gt 0 ]]; then
            RECOVER_NOT_READY="$jobs job(s) still assigned to $node"
            return 1
        fi
    fi
    return 0
}

## Attempt history -- the only state this carries between runs. Tab separated
## with the reason last: a Slurm reason is free text with spaces in it.
recover_record() {
    local epoch="$1" class="$2" state="$3" setter="$4" reason="$5"
    [[ -n "$RECOVER_LOG" ]] || return 0
    mkdir -p "$(dirname "$RECOVER_LOG")" 2>/dev/null
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$epoch" "$(date -d "@$epoch" '+%F %T' 2>/dev/null)" "$class" "$state" "$setter" \
        "$(tr '\t\n' '  ' <<<"$reason")" >> "$RECOVER_LOG" 2>/dev/null
    ## Same 200 kB / tail -500 bound as trigger.log; this file only ever grows.
    if [[ "$(stat -c %s "$RECOVER_LOG" 2>/dev/null || echo 0)" -gt 200000 ]]; then
        tail -500 "$RECOVER_LOG" > "$RECOVER_LOG.tmp" 2>/dev/null &&
            mv "$RECOVER_LOG.tmp" "$RECOVER_LOG" 2>/dev/null
    fi
}

## Read from the log rather than a variable, so an operator sees the same number
## the gate saw.
recover_attempts_in_window() {
    local now="$1" cutoff n
    cutoff=$(( now - RECOVER_WINDOW_HOURS * 3600 ))
    [[ -f "$RECOVER_LOG" ]] || { printf '0'; return 0; }
    n=$(awk -F'\t' -v c="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= c { n++ } END { print n + 0 }' "$RECOVER_LOG")
    printf '%s' "${n:-0}"
}

## ── Entry point ───────────────────────────────────────────────────────────
##
## Returns 0 only when the node was resumed (or would have been, under
## --explain), so a caller can re-read the node state on 0. RECOVER_RESULT
## carries the outcome: resumed, not-drained, disabled, class, not-ready,
## rate-limited, unknown-node.
RECOVER_RESULT=""
slurm_recover_node() {
    local node="${1:-$HOSTNAME}"
    local line state setter when reason class now attempts out
    RECOVER_RESULT=""

    if ! setting_enabled "$RECOVER_SLURM_DRAINS"; then
        RECOVER_RESULT="disabled"
        return 1
    fi

    ## Reason last, so free text with spaces in it cannot shift a field.
    line=$(sinfo -N -n "$node" -h -o '%T|%u|%H|%E' 2>/dev/null | head -1)
    if [[ -z "$line" ]]; then
        RECOVER_RESULT="unknown-node"
        return 1
    fi
    state="${line%%|*}"; line="${line#*|}"
    setter="${line%%|*}"; line="${line#*|}"
    when="${line%%|*}"
    reason="${line#*|}"
    [[ "$setter" == "none" ]] && setter=""
    recover_reason_empty "$reason" && reason=""

    if ! recover_state_recoverable "$state"; then
        RECOVER_RESULT="not-drained"
        return 1
    fi

    class=$(recover_classify "$reason" "$setter")
    if [[ " $RECOVER_ACCEPT " != *" $class "* ]]; then
        ## Named, not silent: "nothing happened" and "an operator drained this
        ## and we respected it" look identical from outside.
        recover_log "recover skipped: $node is $state for a $class reason -- '${reason:-<empty>}'${setter:+ set by $setter}${when:+ at $when}. This caller clears [${RECOVER_ACCEPT:-nothing}]."
        RECOVER_RESULT="class"
        return 1
    fi

    now=$(date +%s)
    attempts=$(recover_attempts_in_window "$now")
    if [[ "$attempts" -ge "$RECOVER_MAX_ATTEMPTS" ]]; then
        ## Left exactly as Slurm set it, deliberately not re-drained under
        ## $DRAIN_MARKER -- that would hand it to resume_node() and restart the
        ## flapping this cap exists to stop.
        recover_log "recover skipped: $node recovered $attempts time(s) in the last ${RECOVER_WINDOW_HOURS}h (limit $RECOVER_MAX_ATTEMPTS) -- still '${reason:-<empty>}'. Left drained for an operator; see $RECOVER_LOG."
        RECOVER_RESULT="rate-limited"
        return 1
    fi

    if ! recover_node_ready "$node"; then
        recover_log "recover held: $node is $state ('${reason:-<empty>}', $class) but $RECOVER_NOT_READY"
        RECOVER_RESULT="not-ready"
        return 1
    fi

    if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
        recover_log "WOULD RECOVER $node: $state '${reason:-<empty>}' ($class${setter:+, set by $setter}) -- attempt $((attempts + 1))/$RECOVER_MAX_ATTEMPTS in ${RECOVER_WINDOW_HOURS}h"
        RECOVER_RESULT="resumed"
        return 0
    fi

    out=$(scontrol update nodename="$node" state=RESUME 2>&1)
    if [[ -n "$out" ]]; then
        ## scontrol is quiet on success, so any output is the failure --
        ## typically "Invalid user id". Not recorded as an attempt: it did not
        ## happen.
        recover_log "RECOVER FAILED $node: scontrol update state=RESUME -- $out"
        RECOVER_RESULT="not-ready"
        return 1
    fi

    recover_record "$now" "$class" "$state" "$setter" "$reason"
    recover_log "RECOVER: $node was $state '${reason:-<empty>}' ($class${setter:+, set by $setter}${when:+ at $when}) -- resumed, attempt $((attempts + 1))/$RECOVER_MAX_ATTEMPTS in ${RECOVER_WINDOW_HOURS}h"
    # shellcheck disable=SC2034  # read by the sourcing caller and asserted on
                                 # by tests/recover-test.sh; dead only in here
    RECOVER_RESULT="resumed"
    return 0
}

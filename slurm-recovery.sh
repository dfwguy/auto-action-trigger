#!/bin/bash
#
# Clearing drains that Slurm set itself. Sourced by actions/launch_job.sh and
# actions/node_health.sh -- never executed. The four reason classes, the three
# discriminators that protect an operator drain, the readiness checks and the
# rate limit are in docs/explanation/drain-recovery.md.
#
# Callers set before calling slurm_recover_node: RECOVER_ACCEPT (classes this
# caller may clear, space separated -- launch_job.sh "machine", node_health.sh
# after a clean run "machine health"), RECOVER_LOG, RECOVER_DRY_RUN,
# SNAPSHOT_RESULTS (the results tree the node view is read from), and optionally
# recover_log(). Everything else comes from settings.sh.
#
# Nothing here asks slurmctld anything: the state, the reason, the configured
# counts and the jobs assigned to the node all come out of that view.
# See docs/explanation/the-fleet-snapshot.md.

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
## reason-map.sh, shared rather than copied. See
## docs/reference/health-checks.md#reading-the-reason-field.
## Not re-sourced if a caller already did.
if ! declare -F canonicalize_reason >/dev/null 2>&1; then
    _recover_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"
    [[ -f "$_recover_home/reason-map.sh" ]] && source "$_recover_home/reason-map.sh"
fi

## The drain and the slurmd restart below are the two things here that need
## root. See docs/explanation/running-unprivileged.md.
if ! declare -F priv >/dev/null 2>&1; then
    _recover_home="${SETTINGS_HOME:-${home:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}"
    [[ -f "$_recover_home/priv.sh" ]] && source "$_recover_home/priv.sh"
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

## Slurm appends " : Not responding" to whatever reason the node already had,
## and signs the result itself -- so an operator's drain arrives set by slurm,
## reading `BF3 TEST BY AIC : Not responding`. Everything downstream judges
## what was there first. docs/explanation/drain-recovery.md#reasons-slurm-appends-to
recover_base_reason() {
    local reason="$1" base
    if [[ "${reason,,}" =~ ^(.*[^[:space:]])[[:space:]]*:[[:space:]]*not[[:space:]]responding[[:space:]]*$ ]]; then
        ## Sliced by length rather than used directly: BASH_REMATCH is off the
        ## lowercased copy, and the reason is shown to people.
        base="${reason:0:${#BASH_REMATCH[1]}}"
        [[ -n "$base" ]] && { printf '%s' "$base"; return 0; }
    fi
    printf '%s' "$reason"
}

## marker | health | machine | operator, most specific first: a benchmark drain
## whose text happens to contain "prolog" must not be read as Slurm's.
## docs/explanation/drain-recovery.md#how-an-operators-drain-is-protected
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

## ── Count drains ──────────────────────────────────────────────────────────
##
## The two reasons that mean slurmd registered before the hardware was ready.
## docs/explanation/drain-recovery.md#a-count-drain-is-checked-against-the-hardware
recover_count_reason() {
    local reason="${1,,}"
    [[ "$reason" == *"gres/gpu count"* ]] && { printf 'gpu'; return 0; }
    [[ "$reason" == *"low socket"* || "$reason" == *"low cpus"* ]] && { printf 'cpu'; return 0; }
    return 1
}

## What the node has now, read on the node itself. Three answers, not two:
## 0 is a count and a real one -- a node whose driver is down reports zero GPUs
## and means it. 2 is the tool being absent, which proves nothing either way;
## 1 is the tool failing, which is itself the node saying it is not ready.
recover_visible_gpus() {
    local out
    command -v nvidia-smi >/dev/null 2>&1 || return 2
    out=$(nvidia-smi -L 2>/dev/null) || return 1
    printf '%s' "$(grep -c '^GPU [0-9]' <<<"$out")"
}

## `slurmd -C` is what slurmd would register, which is the number that matters
## here; nproc is the fallback when slurmd is not on this caller's PATH.
recover_visible_cpus() {
    local n=""
    if command -v slurmd >/dev/null 2>&1; then
        n=$(slurmd -C 2>/dev/null | grep -o 'CPUs=[0-9]*' | head -1)
        n="${n#CPUs=}"
    fi
    [[ -n "$n" ]] || n=$(nproc --all 2>/dev/null)
    [[ "${n:-0}" -gt 0 ]] 2>/dev/null || return 2
    printf '%s' "$n"
}

## What the config asks for. Slurm states it in the GRES reason itself, which is
## better than any lookup; the node view carries the configured values as the
## fallback, and is the only source for CPUs.
recover_configured_gpus() {
    local reason="$2" raw n
    ## Two spellings in the wild: `... lower than configured (4)` and
    ## `... reported lower than configured (0 < 4)`, reported first.
    if [[ "$reason" =~ \([0-9]+[[:space:]]*\<[[:space:]]*([0-9]+)[[:space:]]*\) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$reason" =~ configured[[:space:]]*\(([0-9]+)\) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"; return 0
    fi
    ## Typed GRES is `gpu:gb200:4`, untyped `gpu:4`; the count is the last field
    ## once the `(S:0-3)` topology suffix is off, and that suffix has its own colon.
    raw="${RECOVER_GRES:-}"; raw="${raw%%(*}"
    n="${raw##*:}"; n="${n%%[!0-9]*}"
    [[ -n "$n" ]] || return 1
    printf '%s' "$n"
}

recover_configured_cpus() {
    local n="${RECOVER_CPUTOT:-}"
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}

## A count drain is the one class the node can prove wrong: the hardware is
## either there now or it is not. Short means hold, with the numbers -- no
## resume, and no attempt spent. Present means slurmctld is holding a count
## that was true for a few seconds after boot, which a resume does not refresh.
RECOVER_STALE_COUNT=0
recover_counts_ready() {
    local node="$1" reason="$2" kind want have rc
    RECOVER_STALE_COUNT=0
    kind=$(recover_count_reason "$reason") || return 0

    case "$kind" in
        gpu) want=$(recover_configured_gpus "$node" "$reason")
             have=$(recover_visible_gpus); rc=$? ;;
        cpu) want=$(recover_configured_cpus)
             have=$(recover_visible_cpus); rc=$? ;;
    esac

    ## The tool answering with an error is not the same as it not being there.
    if [[ "$rc" -eq 1 ]]; then
        RECOVER_NOT_READY="the ${kind^^} inventory cannot be read at all on $node, which is the drain's own complaint -- a resume would earn it again"
        return 1
    fi
    ## No proof either way: carry on as this did before either count was read,
    ## rather than holding a node on a number we could not get.
    [[ "$rc" -eq 0 && -n "$want" && -n "$have" ]] || return 0

    if [[ "$have" -lt "$want" ]]; then
        RECOVER_NOT_READY="only $have of $want ${kind^^}s are present, so the drain is currently right -- a resume would earn it again on the next registration"
        return 1
    fi
    RECOVER_STALE_COUNT=1
    return 0
}

## ── Rogue processes ───────────────────────────────────────────────────────
##
## The drain reason says `rogueprocess` and stops there; the process it
## objected to is only ever written down in the pre-job check's own log.
## docs/explanation/drain-recovery.md#a-rogue-process-drain-names-its-process
## Is this live process one the check flagged? A pid is not proof on its own --
## pids are reused, and the flagged command is usually one the node runs anyway,
## so `sshd` alone would match the sshd daemon on every node forever. The
## command has to be one of the flagged set, and the user has to place it:
## owning the process, or named in its args as `sshd: nvis-ib [priv]` is.
recover_rogue_matches() {
    local flagged="$1" args="$2" owner="$3" tok cmd user
    ## In a variable, not inline: `[[ =~ ]]` will not parse an unquoted pattern
    ## carrying escaped parentheses.
    local pat='^[[:space:]]*(.+[^[:space:]])[[:space:]]*\(([^)]*)\)[[:space:]]*$'
    local IFS=,
    for tok in $flagged; do
        [[ "$tok" =~ $pat ]] || continue
        cmd="${BASH_REMATCH[1]}"; user="${BASH_REMATCH[2]}"
        [[ "$args" == *"${cmd##*/}"* ]] || continue
        [[ -z "$user" || "$owner" == "$user" || "$args" == *"$user"* ]] || continue
        return 0
    done
    return 1
}

## What the pre-job check objected to, and whether it is still there. Also sets
## RECOVER_PREJOB_FAILED to every check that failed, which is the only record of
## why a `Prolog error` drain happened at all.
## RECOVER_PREJOB_NONE carries why there was nothing to read, so that every
## exit here is traceable. See
## docs/explanation/drain-recovery.md#when-nothing-names-the-check.
RECOVER_ROGUE=""
RECOVER_PREJOB_FAILED=""
RECOVER_PREJOB_NONE=""
recover_rogue_still_running() {
    local when="$1"
    local dir="${RECOVER_PREJOB_LOGS:-}" log line flagged pids pid args owner drained mtime
    RECOVER_ROGUE=""
    RECOVER_PREJOB_FAILED=""
    RECOVER_PREJOB_NONE=""
    if [[ -z "$dir" ]]; then
        RECOVER_PREJOB_NONE="RECOVER_PREJOB_LOGS is empty, so nothing reads it"
        return 1
    fi
    if [[ ! -d "$dir" ]]; then
        RECOVER_PREJOB_NONE="$dir does not exist on this node"
        return 1
    fi

    ## Only failures land here, one file per job, and nothing prunes them.
    # shellcheck disable=SC2012  # sorting by mtime is the point; these are
                                 # job.<id>.log and cannot contain a newline
    log=$(ls -1t "$dir"/job.*.log 2>/dev/null | head -1)
    if [[ -z "$log" || ! -r "$log" ]]; then
        RECOVER_PREJOB_NONE="no readable job.*.log in $dir"
        return 1
    fi

    ## So the newest log can be a record of an incident that is long over. Only
    ## one written around this drain can be the one that caused it.
    if [[ -n "$when" ]] && drained=$(date -d "$when" +%s 2>/dev/null); then
        mtime=$(stat -c %Y "$log" 2>/dev/null || printf 0)
        if [[ "$mtime" -lt $(( drained - RECOVER_PREJOB_SLACK_SECS )) ]]; then
            RECOVER_PREJOB_NONE="the newest log in $dir is ${log##*/}, written $(( drained - mtime ))s before the drain (slack ${RECOVER_PREJOB_SLACK_SECS}s), so it is a different incident"
            return 1
        fi
    fi

    while IFS= read -r line; do
        [[ "$line" == *" is FAIL"* ]] || continue
        RECOVER_PREJOB_FAILED+="${RECOVER_PREJOB_FAILED:+, }${line%% is FAIL*}"

        ## Only the rogue-process check names processes. Every other check puts
        ## its own number between the same markers -- `dmesg is FAIL, /* 4790 */
        ## matches for regex: hardware error` is a count, not a pid.
        [[ "${line,,}" == rogueprocess*is\ fail* ]] || continue

        ## `CMD (USER), CMD (USER)/* PID, PID */` -- one pid list at the end
        ## rather than a pid per command, so the two are matched as sets.
        [[ "$line" =~ /\*([^*]*)\*/ ]] || continue
        pids="${BASH_REMATCH[1]//,/ }"
        flagged="${line%%"/*"*}"; flagged="${flagged#*" is FAIL,"}"

        for pid in $pids; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            args=$(ps -p "$pid" -o args= 2>/dev/null)
            [[ -n "$args" ]] || continue
            owner=$(ps -p "$pid" -o user= 2>/dev/null)
            owner="${owner//[[:space:]]/}"
            recover_rogue_matches "$flagged" "$args" "$owner" || continue
            RECOVER_ROGUE="pid $pid ($owner) '$args', flagged by ${log##*/} as [${flagged# }]"
            return 0
        done
    done < "$log"
    [[ -n "$RECOVER_PREJOB_FAILED" ]] ||
        RECOVER_PREJOB_NONE="${log##*/} in $dir names no failed check"
    return 1
}

## The one restart path, for both of the reasons this library has to use one.
## `reset-failed` first: a slurmd that tripped systemd's start limit refuses
## `restart` until that counter is cleared, and it is the state an unevenly
## rebooted node is most often found in. docs/explanation/drain-recovery.md#restarting-slurmd
recover_slurmd_restart() {
    local node="$1" why="$2" waited=0
    command -v systemctl >/dev/null 2>&1 || return 0

    if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
        recover_log "WOULD RESTART slurmd on $node: $why"
        return 0
    fi

    recover_log "restarting slurmd on $node: $why"
    priv systemctl reset-failed slurmd 2>/dev/null
    priv systemctl restart slurmd 2>/dev/null
    while ! systemctl is-active --quiet slurmd 2>/dev/null; do
        if [[ "$waited" -ge "${RECOVER_SLURMD_WAIT:-0}" ]]; then
            RECOVER_NOT_READY="slurmd is $(systemctl is-active slurmd 2>/dev/null) ${RECOVER_SLURMD_WAIT}s after a restart -- resuming would only put $node back into down*. 'journalctl -u slurmd -n 50' on the node"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 0
}

## slurmctld keeps the counts from the registration that drained the node, and
## a resume does not ask for a new one. Restarting slurmd does. Only ever
## reached once the hardware has proved the cached count wrong.
recover_reregister() {
    local node="$1"
    if ! setting_enabled "$RECOVER_REREGISTER"; then
        recover_log "recover note: $node has the hardware its config asks for, but slurmctld still holds the count slurmd registered without it. RECOVER_REREGISTER=$RECOVER_REREGISTER, so nothing re-registers it and Slurm is likely to drain $node again."
        return 0
    fi
    recover_slurmd_restart "$node" \
        "the hardware its config asks for is present, and slurmctld is holding the count slurmd registered before it was"
}

## Still coming up? Every count read below is a moving number until boot
## finishes, so nothing is judged before then -- the node is simply left for
## the next cycle. docs/explanation/drain-recovery.md#nothing-is-judged-mid-boot
recover_boot_settled() {
    local node="$1" up state
    if [[ "${RECOVER_MIN_UPTIME_SECS:-0}" -gt 0 && -r /proc/uptime ]]; then
        read -r up _ < /proc/uptime
        up="${up%%.*}"
        if [[ "${up:-0}" -lt "$RECOVER_MIN_UPTIME_SECS" ]]; then
            RECOVER_NOT_READY="$node has been up ${up}s, under RECOVER_MIN_UPTIME_SECS=$RECOVER_MIN_UPTIME_SECS -- what it reports is still changing, so it is left for the next cycle"
            return 1
        fi
    fi
    ## systemd's own answer, which outlasts any uptime guess on a slow boot.
    ## Anything it cannot answer is not read as "still booting".
    if command -v systemctl >/dev/null 2>&1; then
        state=$(systemctl is-system-running 2>/dev/null)
        case "$state" in
            initializing|starting|stopping|maintenance)
                RECOVER_NOT_READY="systemd on $node is '$state', not finished -- $node is left for the next cycle"
                return 1 ;;
        esac
    fi
    return 0
}

## Has the condition actually cleared? Deliberately narrow -- a check that
## cannot be satisfied is a node that never comes back. Sets RECOVER_NOT_READY
## to why. docs/explanation/drain-recovery.md#why-a-resume-is-not-enough-on-its-own
RECOVER_NOT_READY=""
RECOVER_GPU_PIDS=""
recover_node_ready() {
    local node="$1" reason="$2" when="$3" pids jobs
    RECOVER_NOT_READY=""
    RECOVER_GPU_PIDS=""

    ## First: a node still booting cannot answer any of the questions below,
    ## and restarting its slurmd mid-boot is its own race.
    recover_boot_settled "$node" || return 1

    ## Before the two gates below, deliberately: a job assigned to a node whose
    ## slurmd is dead needs the slurmd back to carry on, and the resume still
    ## waits for the job. docs/explanation/drain-recovery.md#restarting-slurmd
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet slurmd 2>/dev/null; then
            local unit; unit=$(systemctl is-active slurmd 2>/dev/null)
            if ! setting_enabled "$RECOVER_RESTART_SLURMD"; then
                RECOVER_NOT_READY="slurmd is '$unit' on $node and RECOVER_RESTART_SLURMD=$RECOVER_RESTART_SLURMD -- 'systemctl restart slurmd' on the node, or set it to yes"
                return 1
            fi
            recover_slurmd_restart "$node" \
                "slurmd is '$unit', and a node whose slurmd is not running does not come back without it" || return 1
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1; then
        pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d ' ' | grep -v '^$' | tr '\n' ' ')
        if [[ -n "$pids" ]]; then
            ## Published for the unkillable-step gate, which needs the pid set
            ## itself and not just the fact that there was one.
            RECOVER_GPU_PIDS="${pids% }"
            RECOVER_NOT_READY="compute processes still on the GPUs (pids ${pids% })"
            return 1
        fi
    fi

    ## The GPU test above cannot see what drained this one: the pre-job check
    ## objects to processes that hold no GPU, a login shell among them. Keyed on
    ## `prolog` as well, because that is what the drain reason usually says --
    ## the pre-job check is what the prolog runs, and only its own log records
    ## that the failure was a rogue process.
    if [[ "${reason,,}" =~ (rogue[[:space:]]?process|prolog) ]]; then
        if recover_rogue_still_running "$when"; then
            RECOVER_NOT_READY="the process the pre-job check objected to is still running -- $RECOVER_ROGUE. Resuming would only fail the next job's pre-job check the same way"
            return 1
        fi
        ## The drain reason says `Prolog error` and no more. Naming the check
        ## that failed is the difference between a node that flaps for a reason
        ## nobody can see and one that says `dmesg is FAIL ... hardware error`.
        if [[ -n "$RECOVER_PREJOB_FAILED" ]]; then
            recover_log "recover note: the pre-job check that drained $node failed on [$RECOVER_PREJOB_FAILED]; nothing it named is still running, so this is a resume rather than a hold. Repeats here are that check failing again, not this."
        elif [[ -n "$RECOVER_PREJOB_NONE" ]]; then
            recover_log "recover note: nothing on $node names the check that drained it -- $RECOVER_PREJOB_NONE. This resume is blind, and a repeat here cannot be told from a new fault."
        fi
    fi

    ## From the node view, not a query per drained node per cycle. The caller has
    ## already refused to run at all without one, so an empty list here is Slurm
    ## saying nothing is assigned rather than nobody having asked.
    jobs=$(snapshot_jobs_here | grep -c .)
    if [[ "$jobs" -gt 0 ]]; then
        RECOVER_NOT_READY="$jobs job(s) still assigned to $node"
        return 1
    fi

    ## Last, so a slurmd restart can never happen under a job or a live GPU
    ## process. docs/explanation/drain-recovery.md#a-count-drain-is-checked-against-the-hardware
    recover_counts_ready "$node" "$reason" || return 1
    if [[ "$RECOVER_STALE_COUNT" -eq 1 ]]; then
        recover_reregister "$node" || return 1
    fi
    return 0
}

## Attempt history, one of the two state files this keeps between runs. Tab
## separated with the reason last: a Slurm reason is free text with spaces.
## Field 7 is the pre-job check, because `Prolog error` in field 6 does not say
## which. trigger.log carries the same fact and rotates inside a day; this file
## is what is left. docs/explanation/drain-recovery.md#when-nothing-names-the-check
recover_record() {
    local epoch="$1" class="$2" state="$3" setter="$4" reason="$5" cause
    [[ -n "$RECOVER_LOG" ]] || return 0
    mkdir -p "$(dirname "$RECOVER_LOG")" 2>/dev/null
    cause="${RECOVER_PREJOB_FAILED:-${RECOVER_PREJOB_NONE:+unnamed: $RECOVER_PREJOB_NONE}}"
    ## Expansion rather than a `tr` herestring, which appended the herestring's
    ## own newline to the last field as a trailing space.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$epoch" "$(date -d "@$epoch" '+%F %T' 2>/dev/null)" "$class" "$state" "$setter" \
        "${reason//[$'\t\n']/ }" "${cause//[$'\t\n']/ }" \
        >> "$RECOVER_LOG" 2>/dev/null
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

## ── A step that outlives its own kill ─────────────────────────────────────
##
## Second state file, beside recover.log: the epoch this pid set was first
## seen, so a hold can be told from a wedge. A changed pid set is a different
## incident and restarts the clock.
## docs/explanation/drain-recovery.md#a-step-that-outlives-its-own-kill
recover_unkillable_stamp() {
    [[ -n "$RECOVER_LOG" ]] || return 1
    printf '%s/unkillable.stamp' "$(dirname "$RECOVER_LOG")"
}

recover_unkillable_elapsed() {
    local pids="$1" now="$2" file seen_epoch="" seen_pids=""
    file=$(recover_unkillable_stamp) || return 1
    [[ -r "$file" ]] && IFS=$'\t' read -r seen_epoch seen_pids < "$file"
    if [[ "$seen_pids" != "$pids" || ! "$seen_epoch" =~ ^[0-9]+$ ]]; then
        mkdir -p "$(dirname "$file")" 2>/dev/null
        printf '%s\t%s\n' "$now" "$pids" > "$file" 2>/dev/null || return 1
        printf '0'
        return 0
    fi
    printf '%s' "$(( now - seen_epoch ))"
}

## `%e` is start plus the job's own limit, absolute, so nothing here parses a
## Slurm duration. An unlimited job reports `N/A` and is never taken out of
## service automatically -- there is no limit to have exceeded, so no evidence
## the step is wedged rather than long.
## docs/explanation/drain-recovery.md#a-step-that-outlives-its-own-kill
RECOVER_LIMIT_WHY=""
recover_jobs_past_limit() {
    local node="$1" now="$2" epoch live=0 _id _state _user _name
    RECOVER_LIMIT_WHY=""
    while IFS=$'\t' read -r _id _state _user epoch _name; do
        [[ -n "$_id" ]] || continue
        ## `none` is the view's word for a job with no limit to have exceeded.
        if [[ "$epoch" == none ]]; then
            RECOVER_LIMIT_WHY="a job on $node has no time limit -- taking a node out of service over an unlimited job is left to an operator"
            return 1
        fi
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
            RECOVER_LIMIT_WHY="the node view gave an end time this cannot read ('$epoch')"
            return 1
        fi
        [[ "$epoch" -gt "$now" ]] && live=1
    done < <(snapshot_jobs_here)
    if [[ "$live" -eq 1 ]]; then
        RECOVER_LIMIT_WHY="a job on $node is still inside its own time limit"
        return 1
    fi
    return 0
}

## Appended to the held line while the clock runs, so the countdown is visible
## before it fires rather than only after.
RECOVER_UNKILLABLE_IN=""
## Returns 0 when the node was marked DOWN, or would have been under
## --explain. Deliberately not recorded in recover.log: that history is the
## rate limit on *resumes*, and nothing here resumed anything.
recover_down_unkillable() {
    local node="$1" reason="$2" now="$3" pids="$4" elapsed count text out
    RECOVER_UNKILLABLE_IN=""
    [[ -n "$pids" ]] || return 1
    [[ -n "$RECOVER_UNKILLABLE_REASONS" ]] || return 1
    grep -qEi -- "$RECOVER_UNKILLABLE_REASONS" <<<"$reason" || return 1

    elapsed=$(recover_unkillable_elapsed "$pids" "$now") || return 1
    if [[ "$elapsed" -lt "$RECOVER_UNKILLABLE_AFTER_SECS" ]]; then
        RECOVER_UNKILLABLE_IN="; unchanged for ${elapsed}s of ${RECOVER_UNKILLABLE_AFTER_SECS}s before this counts as a step that outlived its own kill"
        return 1
    fi

    ## Two independent proofs, because either alone is survivable: the pid set
    ## has not moved, *and* Slurm agrees nothing here is still owed time.
    if ! recover_jobs_past_limit "$node" "$now"; then
        RECOVER_UNKILLABLE_IN="; unchanged for ${elapsed}s, but $RECOVER_LIMIT_WHY -- not a wedged step as far as this can tell"
        return 1
    fi

    ## Detection is not gated on the switch, only the action is: a step that
    ## outlived its kill is a reboot whoever does it, and this is the only
    ## thing that says so. docs/how-to/clear-an-unkillable-step.md
    if ! setting_enabled "$RECOVER_DOWN_UNKILLABLE"; then
        RECOVER_UNKILLABLE_IN="; unchanged for ${elapsed}s and past every job's time limit -- the step outlived its own kill and $node needs a reboot. RECOVER_DOWN_UNKILLABLE=$RECOVER_DOWN_UNKILLABLE, so nothing here marks it DOWN. See docs/how-to/clear-an-unkillable-step.md"
        return 1
    fi

    ## The wording is load-bearing: it must not match RECOVER_REASONS or carry
    ## DRAIN_MARKER, or this hands the node straight back to the recovery it
    ## exists to stop. tests/recover-test.sh asserts the class.
    count=$(wc -w <<<"$pids")
    text="unkillable job: ${count// /} GPU process(es) survived ${elapsed}s past their step kill -- needs manual intervention"

    if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
        recover_log "WOULD MARK DOWN $node: $text (pids $pids)"
        return 0
    fi

    out=$(scontrol_update nodename="$node" state=DOWN reason="$text" 2>&1)
    if [[ -n "$out" ]]; then
        recover_log "DOWN FAILED $node: scontrol update state=DOWN -- $out"
        return 1
    fi
    recover_log "DOWN $node: $text (pids $pids). Nothing here clears this -- see docs/how-to/clear-an-unkillable-step.md"
    return 0
}

## ── Entry point ───────────────────────────────────────────────────────────
##
## Returns 0 only when the node was resumed (or would have been, under
## --explain), so a caller can re-read the node state on 0. RECOVER_RESULT
## carries the outcome: resumed, not-drained, disabled, class, not-ready,
## downed, rate-limited, unknown-node.
RECOVER_RESULT=""
slurm_recover_node() {
    local node="${1:-$HOSTNAME}"
    local line state setter when reason base class now attempts out art
    RECOVER_RESULT=""

    if ! setting_enabled "$RECOVER_SLURM_DRAINS"; then
        RECOVER_RESULT="disabled"
        return 1
    fi

    ## Every field comes off the node view the watchdog wrote. The `sinfo -N -n`
    ## this replaced was one query per drained node per cycle, and a drained
    ## fleet is the case where that is every node at once.
    ## See docs/explanation/the-fleet-snapshot.md#what-a-node-reads.
    if ! snapshot_load "${SNAPSHOT_RESULTS:-}" "$node"; then
        RECOVER_RESULT="unknown-node"
        recover_log "recover skipped: $node -- ${SNAPSHOT_WHY:-no node view was loaded}. Nothing is resumed on a state nobody could read."
        return 1
    fi
    state="$SNAPSHOT_STATE"
    setter="$SNAPSHOT_SETTER"
    when="$SNAPSHOT_WHEN"
    reason="$SNAPSHOT_REASON"
    RECOVER_GRES="$SNAPSHOT_GRES"
    RECOVER_CPUTOT="$SNAPSHOT_CPUTOT"
    [[ "$setter" == "none" ]] && setter=""
    recover_reason_empty "$reason" && reason=""
    base=$(recover_base_reason "$reason")

    if ! recover_state_recoverable "$state"; then
        RECOVER_RESULT="not-drained"
        return 1
    fi

    class=$(recover_classify "$base" "$setter")
    if [[ " $RECOVER_ACCEPT " != *" $class "* ]]; then
        ## Named, not silent: "nothing happened" and "an operator drained this
        ## and we respected it" look identical from outside.
        art="a"; [[ "$class" == operator ]] && art="an"
        recover_log "recover skipped: $node is $state for $art $class reason -- '${reason:-<empty>}'${setter:+ set by $setter}${when:+ at $when}. This caller clears [${RECOVER_ACCEPT:-nothing}]."
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

    if ! recover_node_ready "$node" "$base" "$when"; then
        if recover_down_unkillable "$node" "$base" "$now" "$RECOVER_GPU_PIDS"; then
            RECOVER_RESULT="downed"
            return 1
        fi
        recover_log "recover held: $node is $state ('${reason:-<empty>}', $class) but ${RECOVER_NOT_READY}${RECOVER_UNKILLABLE_IN}"
        RECOVER_RESULT="not-ready"
        return 1
    fi

    if [[ "$RECOVER_DRY_RUN" -eq 1 ]]; then
        recover_log "WOULD RECOVER $node: $state '${reason:-<empty>}' ($class${setter:+, set by $setter}) -- attempt $((attempts + 1))/$RECOVER_MAX_ATTEMPTS in ${RECOVER_WINDOW_HOURS}h"
        RECOVER_RESULT="resumed"
        return 0
    fi

    out=$(scontrol_update nodename="$node" state=RESUME 2>&1)
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

#!/bin/bash
#
# Usage: trigger-debug.sh [node-pattern]
#
# Walks the BCM -> sbatch chain and names the broken link. Read-only. Run
# trigger-log.sh first: fresh traces mean every link is intact by definition.
# See docs/how-to/diagnose-nothing-running.md#2-if-the-traces-are-stale-walk-the-chain.
#
#   pattern  node filter, same rules as status-check.sh: bare string matches
#            by prefix, globs honored as written. Per-node sections only.
#
# The links, which the section headers below number against:
#
#   1. action registered in BCM      5. script decides to submit
#   2. trigger registered + enabled  6. sbatch accepts the job
#   3. trigger has the action bound  7. slurm can write the result
#   4. script exists on the node

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
results_dir="$home/results"

## Absence is reported in section 0 rather than here, so the whole answer
## arrives in one place. Nothing is faked: such a tree cannot run anyway.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"

pattern="$1"
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

ACTIONS="node_health_action file_copy_action launch_job_action"
TRIGGERS="NodeHealthTrigger:node_health_action FileCopyTrigger:file_copy_action LaunchJobTrigger:launch_job_action"

problems=0
paused=""
note()  { printf '  %s\n' "$*"; }
bad()   { printf '  ** %s\n' "$*"; problems=$((problems + 1)); }
hdr()   { printf '\n=== %s ===\n' "$*"; }

##############################################################################
hdr "0. Deployed layout"
##############################################################################

## Upstream of every link: a stale tree passes links 1-7 without complaint,
## because BCM fires and the scripts exist -- they just look for paths that
## moved when the job/check/parser sets became SETTINGS-chosen directories.
## See docs/reference/settings.md#which-set-of-things-to-run.
if [[ -z "$SETTINGS_FILE" && ! -f "$home/settings.sh" ]]; then
    bad "settings.sh is missing from $home -- this tree predates the settings split"
    note "  the whole deployment is stale; nothing below is worth reading until it is replaced"
else
    note "settings from ${SETTINGS_FILE:-<neither SETTINGS nor SETTINGS.default found>}"

    ## A pause produces exactly the symptom this script gets run over, so it is
    ## reported ahead of the links -- but not counted as a problem, since it is
    ## a choice someone made. See docs/reference/settings.md#pause-switches.
    for spec in "PAUSE_JOBS:benchmarks:$PAUSE_JOBS" \
                "PAUSE_HEALTH_CHECKS:health checks:$PAUSE_HEALTH_CHECKS" \
                "PAUSE_CONTAINER_COPY:container copy:$PAUSE_CONTAINER_COPY" \
                "PAUSE_RECOVERY:drain recoveries:$PAUSE_RECOVERY"; do
        var="${spec%%:*}"; rest="${spec#*:}"; what="${rest%%:*}"; val="${rest#*:}"
        if setting_enabled "$val"; then
            printf '  ** %s=%s -- %s are paused; this is why nothing is running\n' "$var" "$val" "$what"
            paused="$paused $var"
        fi
    done
    ## A closed cap is the other deliberate answer to "nothing is running", and
    ## the only one that is fleet-wide. See docs/explanation/sequencing.md#the-fleet-wide-cap.
    if [[ "$MAX_QUEUED_JOBS" =~ ^[0-9]+$ ]] && [[ "$MAX_QUEUED_JOBS" -gt 0 ]]; then
        note "MAX_QUEUED_JOBS=$MAX_QUEUED_JOBS -- nodes defer while the fleet is at the cap; trigger-log.sh says when one did"
    elif [[ -n "${MAX_QUEUED_JOBS// /}" && "$MAX_QUEUED_JOBS" != 0 ]]; then
        bad "MAX_QUEUED_JOBS='$MAX_QUEUED_JOBS' is not a whole number -- the cap is ignored and the fleet submits uncapped"
    fi

    [[ -f "$home/verdict.sh" ]] && bad "verdict.sh is at the top level -- stale tree, it belongs in parsers/\$PARSERS/"

    ## Both actions carry on without it by design, so a tree from before the
    ## file existed looks healthy in every other section -- while nodes
    ## accumulate in `drained`. See docs/explanation/drain-recovery.md.
    if [[ ! -f "$home/slurm-recovery.sh" ]]; then
        bad "slurm-recovery.sh is missing from $home -- this tree predates it"
        note "  nodes drained by Slurm itself (prolog, rogue process, no reason) will never be resumed"
    elif setting_enabled "$PAUSE_RECOVERY"; then
        note "PAUSE_RECOVERY=$PAUSE_RECOVERY -- drains are left in place whatever RECOVER_SLURM_DRAINS says"
    elif setting_enabled "$RECOVER_SLURM_DRAINS"; then
        note "RECOVER_SLURM_DRAINS=$RECOVER_SLURM_DRAINS -> clears drains matching '$RECOVER_REASONS' set by [$RECOVER_SETTERS], max $RECOVER_MAX_ATTEMPTS per ${RECOVER_WINDOW_HOURS}h"
    else
        note "RECOVER_SLURM_DRAINS=$RECOVER_SLURM_DRAINS -- drains set by Slurm itself are left in place"
    fi

    for spec in "JOBS:$JOBS:$JOBS_DIR" "HEALTHCHECKS:$HEALTHCHECKS:$HEALTHCHECKS_DIR" "PARSERS:$PARSERS:$PARSERS_DIR"; do
        var="${spec%%:*}"; rest="${spec#*:}"; set_name="${rest%%:*}"; dir="${rest#*:}"
        if [[ ! -d "$dir" ]]; then
            bad "$var=$set_name but $dir does not exist"
        elif [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
            bad "$dir is empty"
        else
            note "$var=$set_name -> $dir"
        fi
    done

    ## A malformed entry is dropped at submit time and only shows in
    ## trigger.log on a cycle that submitted something, so report the effective
    ## list here -- with launch_job.sh's exact test, not a looser one.
    ## See docs/reference/settings.md#what-is-rejected.
    if [[ -n "${JOB_ENV// /}" ]]; then
        bad_env=""; good_env=""
        # shellcheck disable=SC2086  # list-in-a-string, as BENCHMARKS is
        for e in $JOB_ENV; do
            if [[ "$e" =~ ^[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_.:/+@%-]*$ ]]; then
                good_env="$good_env $e"
            else
                bad_env="$bad_env '$e'"
            fi
        done
        [[ -n "$good_env" ]] && note "JOB_ENV -> every benchmark and burn-in job runs with:$good_env"
        [[ -n "$bad_env" ]] && bad "JOB_ENV entries are not NAME=VALUE with a value of [A-Za-z0-9_.:/+@%-] and will be dropped:$bad_env"
    fi

    ## Named separately because it is the one file whose absence stops every
    ## node at once: launch_job.sh exits before submitting anything.
    [[ -d "$PARSERS_DIR" && ! -f "$PARSERS_DIR/verdict.sh" ]] &&
        bad "$PARSERS_DIR/verdict.sh is missing -- launch_job.sh exits before submitting anything"

    ## A name with no .sbatch behind it is skipped per node, per cycle, in
    ## silence -- after a job-set rename, that is the whole sweep. BURNIN is
    ## checked the same way, but only when the phase is on.
    if [[ -d "$JOBS_DIR" ]]; then
        missing=""
        for b in $BENCHMARKS; do
            [[ -f "$JOBS_DIR/$b.sbatch" ]] || missing="$missing $b"
        done
        [[ -n "$missing" ]] && bad "BENCHMARKS names jobs with no .sbatch in $JOBS_DIR:$missing"

        if setting_enabled "$RUN_BURNIN"; then
            if [[ -z "${BURNIN// /}" ]]; then
                bad "RUN_BURNIN=$RUN_BURNIN but BURNIN is empty -- the burn-in phase has no jobs"
            else
                missing=""
                for b in $BURNIN; do
                    [[ -f "$JOBS_DIR/$b.sbatch" ]] || missing="$missing $b"
                done
                [[ -n "$missing" ]] && bad "BURNIN names jobs with no .sbatch in $JOBS_DIR:$missing"
                [[ -z "$missing" ]] && note "RUN_BURNIN=$RUN_BURNIN -> burn-in phase queues:$(printf ' %s' $BURNIN)"
            fi
        else
            note "RUN_BURNIN=$RUN_BURNIN -- burn-in phase off; nodes stop after the benchmark sweep"
        fi
    fi
fi

##############################################################################
hdr "1-3. BCM actions and triggers"
##############################################################################

if ! command -v cmsh >/dev/null 2>&1; then
    note "cmsh not on PATH -- skipping BCM checks (run this on the head node)"
else
    action_list=$(cmsh -c "monitoring action; list" 2>&1)
    for a in $ACTIONS; do
        if grep -qw "$a" <<<"$action_list"; then
            script=$(cmsh -c "monitoring action; use $a; get script" 2>&1 | tr -d '\r')
            note "action $a -> $script"
            [[ -f "$script" ]] || bad "  script does not exist on the head node: $script"
            [[ -x "$script" ]] || bad "  script is not executable: $script"
        else
            bad "action $a is NOT registered -- run pre-post/create-action-trigger.sh"
        fi
    done

    trigger_list=$(cmsh -c "monitoring trigger; list" 2>&1)
    for spec in $TRIGGERS; do
        t="${spec%%:*}"; want="${spec##*:}"
        if ! grep -qw "$t" <<<"$trigger_list"; then
            bad "trigger $t is NOT registered -- run pre-post/create-action-trigger.sh"
            continue
        fi
        ## `get <property>`, never `show` + awk: show's padding and property
        ## names drift between BCM releases, and parsing it silently yields ""
        ## -- which reads as "disabled, nothing bound" on a healthy trigger.
        disabled=$(cmsh -c "monitoring trigger; use $t; get disabled" 2>&1 | tr -d '[:space:]')
        during=$(cmsh -c "monitoring trigger; use $t; get duringactions" 2>&1 | tr -d '\r')
        note "trigger $t: disabled=${disabled:-?} duringactions=${during:-<none>}"
        [[ "$disabled" == "no" ]] || bad "  $t is disabled -- it will never fire"
        ## The failure create-action-trigger.sh calls out by name: the object
        ## exists and looks healthy, fires every cycle, and runs nothing.
        grep -q "$want" <<<"$during" || bad "  $t has no '$want' bound -- fires but runs nothing"
    done
fi

##############################################################################
hdr "4. Node reachability and script presence"
##############################################################################

## A node in down* is not running slurmd: the trigger may still fire there, but
## nothing will ever be scheduled onto it. Separated out so that population
## does not get blamed on the trigger.
if command -v sinfo >/dev/null 2>&1; then
    while read -r state count; do
        [[ -z "$state" ]] && continue
        case "$state" in
            *'*') bad "$count nodes in '$state' -- slurmd not responding; the trigger cannot help these" ;;
            idle) note "$count nodes idle -- these SHOULD be picking up work" ;;
            *)    note "$count nodes in '$state'" ;;
        esac
    done < <(sinfo -h -o '%T %D' | sort -k2 -rn)
else
    note "sinfo not on PATH -- skipping slurm state summary"
fi

##############################################################################
hdr "5. What the script decided, per node"
##############################################################################

## No trigger.log at all means the script is not being run on that node --
## which points back at links 1-4, not at slurm.
shopt -s nullglob
## $pattern is a glob by construction and must stay unquoted; quoting looks for
## a directory literally named '*'. Pathname expansion, not word splitting, so
## mapfile/read -a do not apply.
# shellcheck disable=SC2206
nodes=("$results_dir"/$pattern/)
if [[ "${#nodes[@]}" -eq 0 ]]; then
    bad "no node directories under $results_dir match '${1:-*}'"
    note "if you just cleared results/, this is expected until the trigger fires again"
else
    silent=0
    for node_dir in "${nodes[@]}"; do
        node=$(basename "$node_dir")
        if [[ -f "$node_dir/trigger.log" ]]; then
            printf '  %s: %s\n' "$node" "$(tail -1 "$node_dir/trigger.log")"
        else
            silent=$((silent + 1))
        fi
    done
    [[ "$silent" -gt 0 ]] && bad "$silent node dir(s) have no trigger.log -- script is not running there"
fi

##############################################################################
hdr "6-7. Ownership of the result path"
##############################################################################

## A root-owned result directory kills the job at startup with no symptom of
## its own; see docs/reference/layout.md#result-path-ownership. launch_job.sh repairs
## it every cycle, so finding one here means no cycle has run since the tree
## was created, or the script is not reaching this node -- check section 5.
if [[ -d "$results_dir" ]]; then
    owner=$(stat -c '%U %a' "$results_dir")
    note "results/ owned by $owner"
    case "$owner" in
        cmods*) ;;
        *) bad "results/ is not owned by cmods -- sbatch --output will fail for cmods-run jobs" ;;
    esac
    rootowned=0
    while IFS= read -r d; do
        [[ "$(stat -c '%U' "$d")" == "cmods" ]] || rootowned=$((rootowned + 1))
    done < <(find "$results_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if [[ "$rootowned" -gt 0 ]]; then
        bad "$rootowned node dir(s) not owned by cmods -- jobs there cannot write results"
        note "these self-heal on the next monitoring cycle; to fix now:"
        note "  chown -R cmods:cmods $results_dir"
    fi
else
    bad "$results_dir does not exist"
fi

##############################################################################
hdr "Summary"
##############################################################################

if [[ "$problems" -eq 0 ]]; then
    echo "  No broken links found in the trigger chain."
else
    echo "  $problems problem(s) flagged above."
fi
[[ -n "$paused" ]] &&
    echo "  Paused by settings:$paused -- set them to no in ${SETTINGS_FILE##*/} to resume."
cat <<EOF

Next step -- ask one node directly, without waiting for a monitoring cycle:

  pdsh -w <node> '/home/cmods/bringup/actions/launch_job.sh --explain'

That prints every gate the script evaluates and the sbatch commands it would
run, as a dry run: it submits nothing, drains nothing, and archives nothing,
so it is safe while the trigger is live.
EOF

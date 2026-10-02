#!/bin/bash
#
# Usage: check_trigger-debug.sh [node-pattern] [--ask-nodes]
#
# Walks the watchdog -> agent -> sbatch chain and names the broken link.
# Read-only. Run check_trigger-log.sh first: fresh traces mean every link is intact by
# definition.
# See docs/how-to/diagnose-nothing-running.md#2-if-the-traces-are-stale-walk-the-chain.
#
#   pattern     node filter, same rules as report_job-status.sh: bare string matches
#               by prefix, globs honored as written. Per-node sections only.
#   --ask-nodes fan out to the matching nodes for their timer and sudo state,
#               over clush or pdsh. Off by default: links 1-2 are answered from
#               NFS, and this is a shell on every node.
#
# The links, which the section headers below number against:
#
#   1. the watchdog is cycling       5. script decides to submit
#   2. the node's heartbeat is fresh 6. sbatch accepts the job
#   3. linger and timer on the node  7. slurm can write the result
#   4. sudo rules on the node

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Absence is reported in section 0 rather than here, so the whole answer
## arrives in one place. Nothing is faked: such a tree cannot run anyway.
[[ -f "$home/settings.sh" ]] && source "$home/settings.sh"
# shellcheck source=/dev/null
[[ -f "$home/fanout.sh" ]] && source "$home/fanout.sh"
results_dir="$RESULTS_DIR"

ASK_NODES=0
pattern=""
for arg in "$@"; do
    case "$arg" in
        --ask-nodes) ASK_NODES=1 ;;
        *)           pattern="$arg" ;;
    esac
done
if [[ -z "$pattern" ]]; then
    pattern='*'
elif [[ "$pattern" != *[\*\?\[]* ]]; then
    pattern="${pattern}*"
fi

problems=0
paused=""
note()  { printf '  %s\n' "$*"; }
bad()   { printf '  ** %s\n' "$*"; problems=$((problems + 1)); }
hdr()   { printf '\n=== %s ===\n' "$*"; }

##############################################################################
hdr "0. Deployed layout"
##############################################################################

## Upstream of every link: a stale tree passes links 1-7 without complaint,
## because the timers fire and the scripts exist -- they just look for paths that
## moved when the job/check/parser sets became SETTINGS-chosen directories.
## See docs/reference/settings.md#which-set-of-things-to-run.
if [[ -z "$SETTINGS_FILE" && ! -f "$home/settings.sh" ]]; then
    bad "settings.sh is missing from $home -- this tree predates the settings split"
    note "  the whole deployment is stale; nothing below is worth reading until it is replaced"
else
    note "settings from ${SETTINGS_FILE:-<neither SETTINGS nor SETTINGS.default found>}"

    ## A switch turned off produces exactly the symptom this script gets run
    ## over, so it is reported ahead of the links -- but not counted as a
    ## problem, since it is a choice someone made. See
    ## docs/reference/settings.md#run-switches.
    for spec in "RUN_JOBS:benchmarks:$RUN_JOBS" \
                "RUN_HEALTH_CHECKS:health checks:$RUN_HEALTH_CHECKS" \
                "RUN_CONTAINER_COPY:container copy:$RUN_CONTAINER_COPY" \
                "RUN_RECOVERY:drain recoveries:$RUN_RECOVERY" \
                "RUN_ARMING:node arming:$RUN_ARMING"; do
        var="${spec%%:*}"; rest="${spec#*:}"; what="${rest%%:*}"; val="${rest#*:}"
        if setting_disabled "$val"; then
            printf '  ** %s=%s -- %s are paused; this is why nothing is running\n' "$var" "$val" "$what"
            paused="$paused $var"
        fi
    done
    for old in PAUSE_JOBS PAUSE_HEALTH_CHECKS PAUSE_CONTAINER_COPY PAUSE_RECOVERY PAUSE_ARMING; do
        old_setting_present "$old" &&
            bad "SETTINGS still sets $old -- renamed to RUN_${old#PAUSE_} and no longer read"
    done
    ## A benchmark that keeps being cancelled part-way is this and not a fault,
    ## and nothing else in the tree cancels a running job of ours.
    ## See docs/explanation/sequencing.md#getting-out-of-the-way.
    if setting_enabled "$GET_OUT_OF_THE_WAY"; then
        if [[ -f "$home/get-out-of-the-way.sh" ]]; then
            note "GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY (experimental) -- the head-node watchdog cancels our running job on a wanted node for anyone else queued ${GET_OUT_OF_THE_WAY_AFTER_MINUTES}m for it, scanning the fleet every ${GET_OUT_OF_THE_WAY_POLL_MINUTES}m; check_trigger-log.sh says when it did"
        else
            bad "GET_OUT_OF_THE_WAY=$GET_OUT_OF_THE_WAY but get-out-of-the-way.sh is missing from $home -- this tree predates it, and the watchdog cannot give any node back"
        fi
    fi

    [[ -f "$home/verdict.sh" ]] && bad "verdict.sh is at the top level -- stale tree, it belongs in parsers/\$PARSERS/"

    ## Both actions carry on without it by design, so a tree from before the
    ## file existed looks healthy in every other section -- while nodes
    ## accumulate in `drained`. See docs/explanation/drain-recovery.md.
    if [[ ! -f "$home/slurm-recovery.sh" ]]; then
        bad "slurm-recovery.sh is missing from $home -- this tree predates it"
        note "  nodes drained by Slurm itself (prolog, rogue process, no reason) will never be resumed"
    elif setting_disabled "$RUN_RECOVERY"; then
        note "RUN_RECOVERY=$RUN_RECOVERY -- drains are left in place whatever RECOVER_SLURM_DRAINS says"
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
hdr "1. The watchdog"
##############################################################################

## Read from NFS, not from systemd: the reports run on the head node, whoever is
## logged in, and `systemctl --user` cannot be asked about another account.
## The watchdog's own heartbeat is the fact that survives that.
## See docs/explanation/the-agent-and-the-watchdog.md#whose-clock-decides.
own_beat="$results_dir/.supervisor-heartbeat"
sup_log="$results_dir/supervisor.log"
stale_min="${HEARTBEAT_STALE_MINUTES:-10}"

if [[ ! -f "$own_beat" ]]; then
    bad "no $own_beat -- the watchdog has never run here. 'bash $home/agent/install-agent.sh' as $JOB_USER on the head node"
else
    beat_age=$(( $(date +%s) - $(stat -c %Y "$own_beat" 2>/dev/null || echo 0) ))
    if [[ "$beat_age" -gt $(( ${SUPERVISOR_INTERVAL_MINUTES:-2} * 60 * 3 )) ]]; then
        bad "the watchdog last cycled ${beat_age}s ago, well past its ${SUPERVISOR_INTERVAL_MINUTES:-2}m interval -- nothing is arming nodes"
        note "  systemctl --user status bringup-supervisor.timer   (as $JOB_USER on the head node)"
    else
        note "the watchdog cycled ${beat_age}s ago"
    fi
    [[ -f "$sup_log" ]] && note "last said: $(tail -1 "$sup_log")"
fi

for f in agent/supervisor.sh agent/node-agent.sh agent/install-agent.sh \
         agent/units/bringup-agent.service agent/units/bringup-agent.timer; do
    [[ -f "$home/$f" ]] || bad "$home/$f is missing -- this tree predates the agent, or the drop was partial"
done

##############################################################################
hdr "2. Node heartbeats"
##############################################################################

## The one question the whole design turns on, and it costs a stat per node.
## A node whose heartbeat is stale is not running its timer; a node with no
## heartbeat at all has never been armed.
shopt -s nullglob
## $pattern is a glob by construction and must stay unquoted; quoting looks for
## a directory literally named '*'. Pathname expansion, not word splitting.
# shellcheck disable=SC2206
beat_dirs=("$results_dir"/$pattern/)
now_epoch=$(date +%s)
fresh=0; stale=(); never=()
for node_dir in "${beat_dirs[@]}"; do
    node=$(basename "$node_dir")
    if declare -F node_out_of_reporting >/dev/null &&
       node_out_of_reporting "$results_dir" "$node"; then
        continue
    fi
    if [[ ! -f "$node_dir/.heartbeat" ]]; then
        never+=("$node")
    elif [[ $(( now_epoch - $(stat -c %Y "$node_dir/.heartbeat" 2>/dev/null || echo 0) )) -ge $(( stale_min * 60 )) ]]; then
        stale+=("$node")
    else
        fresh=$((fresh + 1))
    fi
done
note "$fresh node(s) cycling within ${stale_min}m"
[[ "${#never[@]}" -gt 0 ]] &&
    bad "${#never[@]} node dir(s) have never written a heartbeat: $(printf '%s ' "${never[@]:0:8}")${never[8]:+...}"
[[ "${#stale[@]}" -gt 0 ]] &&
    bad "${#stale[@]} node(s) stopped writing one: $(printf '%s ' "${stale[@]:0:8}")${stale[8]:+...}"
[[ "${#stale[@]}" -gt 0 || "${#never[@]}" -gt 0 ]] &&
    note "  the watchdog arms these itself, up to ${ARM_MAX_ATTEMPTS:-3} times per ${ARM_WINDOW_HOURS:-24}h -- results/<node>/arm.log says what it heard back"

## What the watchdog itself reads. Only idle and drained are armed, so a fleet
## sitting in down* explains a silent heartbeat without anything being broken.
## See docs/explanation/the-agent-and-the-watchdog.md#which-states-are-armed.
if command -v sinfo >/dev/null 2>&1; then
    while read -r state count; do
        [[ -z "$state" ]] && continue
        case "$state" in
            *'*') bad "$count node(s) in '$state' -- slurmd not answering; the watchdog does not arm these" ;;
            idle) note "$count node(s) idle -- these SHOULD be picking up work" ;;
            *)    note "$count node(s) in '$state'" ;;
        esac
    done < <(sinfo -h -o '%T %D' | sort -k2 -rn)
else
    note "sinfo not on PATH -- skipping the slurm state summary"
fi

##############################################################################
hdr "3-4. Linger, timer and sudo on the nodes"
##############################################################################

## Off unless asked for: this is a shell on every matching node, and links 1-2
## have already answered the same question from NFS for free.
ask_cmd="loginctl show-user $JOB_USER -p Linger --value; \
XDG_RUNTIME_DIR=/run/user/\$(id -u) systemctl --user is-active bringup-agent.timer; \
sudo -n -l >/dev/null 2>&1 && echo sudo-ok || echo sudo-REFUSED"

if [[ "$ASK_NODES" -eq 0 ]]; then
    note "not asked (--ask-nodes runs it). One node by hand, in either spelling:"
    if declare -F fanout_example >/dev/null; then
        fanout_example "<node>" "loginctl show-user $JOB_USER -p Linger --value; systemctl --user is-active bringup-agent.timer"
    fi
elif ! declare -F fanout_resolve >/dev/null; then
    bad "$home/fanout.sh is missing -- --ask-nodes cannot reach the nodes"
elif ! fanout_resolve; then
    bad "$FANOUT_WHY -- --ask-nodes cannot reach the nodes"
else
    ask=("${stale[@]}" "${never[@]}")
    [[ "${#ask[@]}" -eq 0 ]] && ask=("${beat_dirs[@]##*/}")
    joined=$(IFS=,; printf '%s' "${ask[*]}")
    if [[ -z "$joined" ]]; then
        note "no nodes to ask"
    else
        note "asking ${joined//,/ } over $FANOUT_CMD"
        fanout "$joined" "$ask_cmd" | sed 's/^/  /'
    fi
fi

##############################################################################
hdr "5. What the script decided, per node"
##############################################################################

## No trigger.log at all means the sequencer is not being run on that node --
## which points back at links 1-4, not at slurm. The same list section 2 walked.
nodes=("${beat_dirs[@]}")
if [[ "${#nodes[@]}" -eq 0 ]]; then
    bad "no node directories under $results_dir match '${pattern}'"
    note "if you just cleared results/, this is expected until the next cycle"
else
    silent=0
    skipped=0
    for node_dir in "${nodes[@]}"; do
        node=$(basename "$node_dir")
        ## Guarded: settings.sh is only sourced if it exists, and section 0 is
        ## where its absence is reported. See docs/reference/settings.md#hosts-that-are-not-compute-nodes.
        if declare -F node_out_of_reporting >/dev/null &&
           node_out_of_reporting "$results_dir" "$node"; then
            skipped=$((skipped + 1))
            continue
        fi
        if [[ -f "$node_dir/trigger.log" ]]; then
            printf '  %s: %s\n' "$node" "$(tail -1 "$node_dir/trigger.log")"
        else
            silent=$((silent + 1))
        fi
    done
    [[ "$skipped" -gt 0 ]] && note "$skipped host(s) skipped as not compute nodes -- 'check_trigger-log.sh --include-excluded' reads them"
    [[ "$silent" -gt 0 ]] && bad "$silent node dir(s) have no trigger.log -- the sequencer is not running there"
fi

##############################################################################
hdr "6-7. Ownership of the result path"
##############################################################################

## A root-owned result directory kills the job at startup with no symptom of its
## own; see docs/reference/layout.md#result-path-ownership. Nothing repairs it
## now that no cycle runs as root -- one left over from the years that did has to
## be handed over by hand, once.
if [[ -d "$results_dir" ]]; then
    owner=$(stat -c '%U %a' "$results_dir")
    note "results/ owned by $owner"
    ## Exact, not the prefix glob this was: that matched an account the old name
    ## was a prefix of. See docs/explanation/architecture.md#one-account-name.
    [[ "${owner%% *}" == "$JOB_USER" ]] ||
        bad "results/ is not owned by $JOB_USER -- sbatch --output will fail for $JOB_USER-run jobs"
    rootowned=0
    while IFS= read -r d; do
        [[ "$(stat -c '%U' "$d")" == "$JOB_USER" ]] || rootowned=$((rootowned + 1))
    done < <(find "$results_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    if [[ "$rootowned" -gt 0 ]]; then
        bad "$rootowned node dir(s) not owned by $JOB_USER -- jobs there cannot write results"
        note "nothing repairs these on its own; once, as root:"
        note "  chown -R $JOB_USER:$JOB_USER $results_dir"
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

Next step -- ask one node directly, without waiting for its timer:

  clush -w <node> '$BRINGUP_HOME/agent/node-agent.sh --explain'
  pdsh -R ssh -w <node> '$BRINGUP_HOME/agent/node-agent.sh --explain'

That prints every gate the agent and the three steps under it evaluate, as a dry
run: it submits nothing, drains nothing, and archives nothing, so it is safe
while the timer is live. To arm a node that has gone silent:

  clush -w <node> '$BRINGUP_HOME/agent/install-agent.sh'
  pdsh -R ssh -w <node> '$BRINGUP_HOME/agent/install-agent.sh'
EOF

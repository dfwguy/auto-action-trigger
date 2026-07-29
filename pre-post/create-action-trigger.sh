#!/bin/bash
#
# Register the BCM monitoring actions and triggers. Safe to re-run: each object
# is removed before it is added. Removals are silent, adds are not.

################
### ACTIONS  ###
################

## cmsh exits 0 even when a `set` inside the -c string was rejected -- it
## reports on stdout and commits anyway, so inspect output, never exit status.
cm_run() {
    local label="$1" cmd="$2" out
    out=$(cmsh -c "$cmd" 2>&1)
    if grep -qiE 'error:|Unable to find|Some elements were not found|No actions were set|uncommitted changes' <<<"$out"; then
        [[ -n "$out" ]] && printf '%s\n' "$out" >&2
        echo "FAILED: ${label}" >&2
        return 1
    fi
    echo "ok: ${label}"
}

## Remove first, ignoring "does not exist", then add. cmsh has no upsert.
cm_replace() {
    local kind="$1" name="$2" spec="$3"
    cmsh -c "monitoring ${kind}; remove ${name}; commit" >/dev/null 2>&1
    cm_run "${name}" "monitoring ${kind}; add ${spec}; commit"
}

rc=0

## Registers BRINGUP_HOME, not this script's own location -- and so preflights
## the deployed tree, not the checkout. See docs/architecture.md#runtime-paths.
_home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$_home/settings.sh" ]] && source "$_home/settings.sh"
: "${BRINGUP_HOME:=/home/cmods/bringup}"

NODE_HEALTH_SCRIPT="$BRINGUP_HOME/actions/node_health.sh"
FILE_COPY_SCRIPT="$BRINGUP_HOME/actions/file_copy.sh"
LAUNCH_JOB_SCRIPT="$BRINGUP_HOME/actions/launch_job.sh"

####################
### PREFLIGHT    ###
####################

## A 644 action registers fine and silently runs nothing, and the exec bit is
## easy to lose in transit -- so restore it here, or refuse to register.
for s in "$NODE_HEALTH_SCRIPT" "$FILE_COPY_SCRIPT" "$LAUNCH_JOB_SCRIPT"; do
    if [[ ! -f "$s" ]]; then
        echo "FAILED: $s does not exist -- nothing to register" >&2
        rc=1
        continue
    fi
    if [[ ! -x "$s" ]]; then
        if chmod +x "$s" 2>/dev/null; then
            echo "fixed: restored exec bit on $s"
        else
            echo "FAILED: $s is not executable and chmod failed -- the action would register and never run" >&2
            rc=1
        fi
    fi
done

[[ "$rc" -eq 0 ]] || { echo "refusing to register actions while a script is unusable" >&2; exit "$rc"; }

# Action for Node Health
cm_replace action node_health_action \
    "script node_health_action; set runon node; set script ${NODE_HEALTH_SCRIPT}; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no" || rc=1

# Action for Container Copy
## 2m is BCM's hard maximum for an action timeout; the first image sync cannot
## finish inside it, so file_copy.sh detaches the rsync and returns at once.
cm_replace action file_copy_action \
    "script file_copy_action; set runon node; set script ${FILE_COPY_SCRIPT}; set timeout 2m; set nodeenvironment yes; set runinshell no; set mergedelay 0s; set mergetriggers no; set mergemeasurables no" || rc=1

# Action for Launch Job (slurm)
cm_replace action launch_job_action \
    "script launch_job_action; set runon node; set script ${LAUNCH_JOB_SCRIPT}; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no" || rc=1

################
### TRIGGERS ###
################

## duringactions, not enteractions: the latter fires only on the transition
## into UP, so an already-up node never picks up new work. See
## docs/architecture.md.
cm_trigger() {
    local name="$1" action="$2"
    cmsh -c "monitoring trigger; remove ${name}; commit" >/dev/null 2>&1
    cm_run "${name}" "monitoring trigger; add ${name}; use ${name}; set disabled no; set severity 10; set duringactions ${action}; expression; use compare; set measurables devicestatus; set operator ==; set value UP; ..;..; set markentityasfailed no; set markentityasunknown no; commit"
}

# Trigger for Node Health
cm_trigger NodeHealthTrigger node_health_action || rc=1

# Trigger for Container Copy
cm_trigger FileCopyTrigger file_copy_action || rc=1

# Trigger for Launch Job (slurm)
cm_trigger LaunchJobTrigger launch_job_action || rc=1

## if categories are used later
#cmsh -c "monitoring trigger; add NodeHealthTrigger; use NodeHealthTrigger; set disabled no; set severity 10; set enteractions node_health_action; expression; use compare; set measurables spcx_node_ready; set operator ==; set value PASS; ..;..; set markentityasfailed no; set markentityasunknown no; commit"
#cmsh -c "monitoring trigger; add LaunchJobTrigger; use LaunchJobTrigger; set disabled no; set severity 10; set duringactions launch_job_action; expression; use compare; set measurables spcx_node_ready; set operator ==; set value PASS; ..;..; set markentityasfailed no; set markentityasunknown no; commit"

## in progress health checks
#cmsh -c 'monitoring setup; add healthcheck spcx_node_ready; use spcx_node_ready; set script /home/cmods/bringup/actions/valid-node-check.sh; set class Validation; set interval 1m; set disabled no; nodeexecutionfilters; add category spcx_hosts_only; set categories spcx-hosts; commit'

exit "$rc"

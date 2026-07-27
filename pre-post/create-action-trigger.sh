#!/bin/bash
#
# Register the BCM monitoring actions and triggers this framework runs from.
# Safe to re-run: each object is removed before it is added, so an existing
# registration is replaced rather than colliding with "already exists".
#
# Removals are silent by design -- on a first run there is nothing to remove.
# The adds are not silent: a registration that fails quietly is how you end up
# believing a node is being health-checked when it is not.

################
### ACTIONS  ###
################

## cmsh exits 0 even when an individual `set` inside the -c string was
## rejected -- it reports the problem on stdout and carries on to the commit.
## So exit status is useless here and the output has to be inspected. Getting
## this wrong once already produced a trigger with no actions attached that
## still reported success, which is the failure mode most worth catching: the
## object exists, so nothing looks broken until you notice nothing runs.
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

## The path BCM will hand the nodes. It is deliberately not this script's own
## location: BCM invokes the action on the node with no working directory to
## infer one from, so the registration has to carry the absolute NFS path the
## tree is deployed at, which is what BRINGUP_HOME means. Running this from a
## git checkout therefore registers the deployed tree, not the checkout -- the
## preflight below checks the deployed paths for the same reason.
_home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$_home/settings.sh" ]] && source "$_home/settings.sh"
: "${BRINGUP_HOME:=/home/cmods/bringup}"

NODE_HEALTH_SCRIPT="$BRINGUP_HOME/actions/node_health.sh"
FILE_COPY_SCRIPT="$BRINGUP_HOME/actions/file_copy.sh"
LAUNCH_JOB_SCRIPT="$BRINGUP_HOME/actions/launch_job.sh"

####################
### PREFLIGHT    ###
####################

## BCM will register an action pointing at a script it cannot execute and
## report success -- the same "looks healthy, runs nothing" failure the
## trigger check below guards against, one link further down. The exec bit is
## easy to lose in transit: a tarball unpacked through a Windows-mounted path,
## an scp of a single file, an editor that rewrites rather than edits. Check it
## here, restore it where we can, and refuse to register an action whose script
## is missing or still not runnable.
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
## 2m is BCM's hard maximum for an action timeout -- anything larger is
## rejected outright ("above the maximum value of 2m"). The first sync of an
## image is multi-gigabyte over NFS and will not finish inside that, so
## file_copy.sh detaches the rsync and returns immediately rather than being
## killed mid-transfer on every monitoring cycle. See the header there.
cm_replace action file_copy_action \
    "script file_copy_action; set runon node; set script ${FILE_COPY_SCRIPT}; set timeout 2m; set nodeenvironment yes; set runinshell no; set mergedelay 0s; set mergetriggers no; set mergemeasurables no" || rc=1

# Action for Launch Job (slurm)
cm_replace action launch_job_action \
    "script launch_job_action; set runon node; set script ${LAUNCH_JOB_SCRIPT}; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no" || rc=1

################
### TRIGGERS ###
################

## All three use duringactions, which re-fires on every monitoring cycle while
## the device is UP. enteractions fires only on the transition into UP, so a
## node that is already up would never pick up a newly built container image
## until it rebooted.
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

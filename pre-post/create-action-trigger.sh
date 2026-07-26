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

## Remove first, ignoring "does not exist", then add. cmsh has no upsert.
cm_replace() {
    local kind="$1" name="$2" spec="$3"
    cmsh -c "monitoring ${kind}; remove ${name}; commit" >/dev/null 2>&1
    if cmsh -c "monitoring ${kind}; add ${spec}; commit"; then
        echo "ok: ${name}"
    else
        echo "FAILED: ${name}" >&2
        return 1
    fi
}

rc=0

# Action for Node Health
cm_replace action node_health_action \
    'script node_health_action; set runon node; set script /home/cmods/bringup/actions/node_health.sh; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no' || rc=1

# Action for Container Copy
## timeout 10m, not the 2m the others use: the first sync of an image is
## multi-gigabyte over NFS and will not finish in two minutes. A timed-out
## action leaves a partial /tmp/containers, which rsync --partial resumes on
## the next cycle, so an undersized timeout degrades to "converges slowly"
## rather than "never works" -- but it also logs an action failure every cycle
## while it does.
cm_replace action file_copy_action \
    'script file_copy_action; set runon node; set script /home/cmods/bringup/actions/file_copy.sh; set timeout 10m; set nodeenvironment yes; set runinshell no; set mergedelay 0s; set mergetriggers no; set mergemeasurables no' || rc=1

# Action for Launch Job (slurm)
cm_replace action launch_job_action \
    'script launch_job_action; set runon node; set script /home/cmods/bringup/actions/launch_job.sh; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no' || rc=1

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
    if cmsh -c "monitoring trigger; add ${name}; use ${name}; set disabled no; set severity 10; set duringactions ${action}; expression; use compare; set measurables devicestatus; set operator ==; set value UP; ..;..; set markentityasfailed no; set markentityasunknown no; commit"; then
        echo "ok: ${name}"
    else
        echo "FAILED: ${name}" >&2
        return 1
    fi
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

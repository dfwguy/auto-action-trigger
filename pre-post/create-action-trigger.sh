#!/bin/bash
#
#

################
### ACTIONS  ###
################

# Action for Node Health 
cmsh -c 'monitoring; action; add script node_health_action; set runon node; set script /home/cmods/bringup/actions/node_health.sh; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no; commit'

# Action for Container Copy
#cmsh -c 'monitoring; action; add script file_copy_action; set runon node; set script /home/cmods/bringup/actions/file_copy.sh; set timeout 2m; set nodeenvironment yes; set runinshell no; set mergedelay 0s; set mergetriggers no; set mergemeasurables no; commit'

# Action for Lauch Job (slurm)
cmsh -c 'monitoring; action; add script launch_job_action; set runon node; set script /home/cmods/bringup/actions/launch_job.sh; set timeout 2m; set nodeenvironment yes; set runinshell yes; set mergedelay 0s; set mergetriggers yes; set mergemeasurables no; commit'

################
### TRIGGERS ###
################


# Trigger for Node Health
## Based on device UP
cmsh -c "monitoring trigger; add NodeHealthTrigger; use NodeHealthTrigger; set disabled no; set severity 10; set duringactions node_health_action; expression; use compare; set measurables devicestatus; set operator ==; set value UP; ..;..; set markentityasfailed no; set markentityasunknown no; commit"

## if categories are used later
#cmsh -c "monitoring trigger; add NodeHealthTrigger; use NodeHealthTrigger; set disabled no; set severity 10; set enteractions node_health_action; expression; use compare; set measurables spcx_node_ready; set operator ==; set value PASS; ..;..; set markentityasfailed no; set markentityasunknown no; commit"

# Trigger for Container Copy
## Based on device UP
#cmsh -c "monitoring trigger; add FileCopyTrigger; use FileCopyTrigger; set disabled no; set severity 10; set enteractions file_copy_action; expression; use compare; set measurables devicestatus; set operator ==; set value UP; ..;..; set markentityasfailed no; set markentityasunknown no; commit"

# Trigger for Launch Job (slurm)
## Based on device UP
cmsh -c "monitoring trigger; add LaunchJobTrigger; use LaunchJobTrigger; set disabled no; set severity 10; set duringactions launch_job_action; expression; use compare; set measurables devicestatus; set operator ==; set value UP; ..;..; set markentityasfailed no; set markentityasunknown no; commit"

## if categories are used later
#cmsh -c "monitoring trigger; add LaunchJobTrigger; use LaunchJobTrigger; set disabled no; set severity 10; set duringactions launch_job_action; expression; use compare; set measurables spcx_node_ready; set operator ==; set value PASS; ..;..; set markentityasfailed no; set markentityasunknown no; commit"





## in progress health checks
#cmsh -c 'monitoring setup; add healthcheck spcx_node_ready; use spcx_node_ready; set script /home/cmods/bringup/actions/valid-node-check.sh; set class Validation; set interval 1m; set disabled no; nodeexecutionfilters; add category spcx_hosts_only; set categories spcx-hosts; commit'



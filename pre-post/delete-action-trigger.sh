#!/bin/bash
#
# Unregister the BCM actions and triggers created by create-action-trigger.sh.
# See docs/reference/layout.md#directory-layout.

# Actions
cmsh -c "monitoring action; remove node_health_action; commit"

cmsh -c "monitoring action; remove file_copy_action; commit"

cmsh -c "monitoring action; remove launch_job_action; commit"

# Triggers
cmsh -c "monitoring trigger; remove NodeHealthTrigger; commit"

cmsh -c "monitoring trigger; remove FileCopyTrigger; commit"

cmsh -c "monitoring trigger; remove LaunchJobTrigger; commit"



#!/bin/bash
# banner: ########INFO: Check srun/sbatch environment (Expected: the same on every node, and no cpus-per-task in it)
# reason-detail: yes
#
# srun and sbatch read their defaults out of the environment, so a variable this
# node exports joins every job submitted from it -- and the two spellings of
# cpus-per-task disagreeing kills the step before it starts:
#
#   srun: fatal: cpus-per-task set by two different environment variables
#                SLURM_CPUS_PER_TASK=1 != SLURM_TRES_PER_TASK=cpu=4
#
# Three sources, reported apart because the fix is a different file in each.
# See docs/reference/jobs.md#the-step-environment.

pattern='^(SLURM|SBATCH|SRUN|SALLOC)_'

## `none`, not an empty field: an empty line and a missing line diff the same.
listed() { grep -E "$pattern" | sort | paste -s -d' ' | grep . || echo none; }

if [ -n "${SLURM_JOB_ID}" ]; then
  ## Inside an allocation Slurm sets all of these, and none of them is the node's.
  echo "agent: not judged -- running inside job ${SLURM_JOB_ID}"
else
  echo "agent: $(env | listed)"
fi

## `env -i` so this is the site's profile, not whatever the agent was started with.
echo "login: $(env -i HOME="$HOME" USER="$USER" bash -lc env 2>/dev/null | listed)"

## Read by PAM and by no shell, so a leak here is invisible to the line above.
if [ -r /etc/environment ]; then
  echo "pam: $(tr -d '"' < /etc/environment | listed)"
else
  echo "pam: no /etc/environment"
fi

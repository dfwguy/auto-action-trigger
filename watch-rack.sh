#!/bin/bash
if ! command -v scontrol &>/dev/null; then
    source /etc/profile.d/modules.sh
    module load slurm
fi

NODELIST=$1
if [ -z ${NODELIST} ]; then
  NODELIST=${SLURM_JOB_NODELIST}
fi
[ -z ${NODELIST} ] && echo "ERROR: NODELIST is not set. Please provide node list as argument or run within a slurm job." && exit 1



# Only DOWN/drained nodes; empty output is healthy. See docs/reference/scripts.md.
watch -n 20 "echo 'Shows only bad nodes - no nodes listed is a good sign.'; scontrol show node=$NODELIST | awk -F= '/NodeName=/{n=\$2; sub(/ .*/,\"\",n)} /Reason=/{r=\$2; sub(/ \\[.*/,\"\",r); print n, r}'"



#!/bin/bash
#SBATCH -p defq
#SBATCH --ntasks-per-node=4
#SBATCH --gpus-per-node=4

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=example
totalRuns=1

## ------------- job info starts here ------------- ##


echo $HOSTNAME
sleep 15
echo "Test job!"


## ------------- parse info starts here ----------- ##
## This is the template every other job is copied from, so the shape matters:
## check for evidence the work actually happened, THEN for errors. A parse
## block that only greps for a failure string reports DONE for a job that
## produced no output at all -- a missing binary, a container that never
## started, a rank that died during init.

ran=$(grep -cE "^Test job!$" "$RESULT_FILE")
errors=$(grep -iE "srun: error|Segmentation fault|CANCELLED AT" "$RESULT_FILE")

if [[ -n "$RESULT_FILE" && -z "$errors" && "$ran" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi



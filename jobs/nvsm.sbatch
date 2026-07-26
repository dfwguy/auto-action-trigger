#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/nvsm.txt

## Allocation. --exclusive is a JOB-level guarantee and a step inherits only
## what was explicitly requested, so --gres and --mem=0 are stated even though
## --exclusive is supposed to cover them -- nvsm stresses every GPU on the node
## and the srun steps below hold none without that line. --cpus-per-task is
## deliberately absent: it implies --exact and would shrink the step.
## See docs/benchmarks.md.

## AI Factory Testing Plan: NVSM Stress Test -- SNT2 (Hybrid, Exhaustive)
## System-level compute, memory, and thermal stress across all node GPUs.
## Pre-burn-in health gate -- quarantine failing nodes before MNUberGEMM.
## Not run in the TTM variants.
##
## DGX ONLY. nvsm ships with DGX OS and only carries platform definition files
## for DGX platforms; on anything else it exits before doing any work and every
## node of that platform fails identically. It is therefore not in the default
## benchmarks= list in actions/launch_job.sh -- add it only on a DGX site, where
## it also needs a passwordless sudoers grant. See docs/nvsm.md.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvsm

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
srun --ntasks=1 bash -c '
    gpus=$(nvidia-smi -L 2>/dev/null | grep -c "^GPU")
    echo "preflight: $(hostname) gpus=${gpus} cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$gpus" -eq 4 && "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Duration in seconds (~20 min per the plan)
STRESS_SECONDS=1200

unset CUDA_VISIBLE_DEVICES

## nvsm is installed on the host alongside dcgmi -- no container. It refuses to
## run as anyone but root, and Slurm runs the task as the submitting user
## (cmods), so we escalate with sudo. `-n` keeps it non-interactive -- there is
## no tty on a batch task, so a password prompt would hang until the walltime.
## Requires a NOPASSWD sudoers grant for cmods on every compute node; see the
## nvsm section of the README.
if [[ $(id -u) -eq 0 ]]; then
	NVSM=(nvsm)
else
	NVSM=(sudo -n nvsm)
fi

## Fail fast and loudly if we cannot get to nvsm as root, so the parse below
## reports a setup problem instead of a bogus hardware failure.
##
## Keep the output. Not every failure here is a missing sudoers grant, and
## naming one cause for all of them sends the operator to fix a file that is
## already correct -- `sudo -s` working over ssh and this step failing is the
## normal shape of the requiretty and command-list cases below.
preflight=$(srun --ntasks-per-node=1 "${NVSM[@]}" show version 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
	case "$preflight" in
		*"password is required"*|*"not allowed to execute"*|*"may not run"*)
			echo "ERROR: no passwordless sudo grant for $(id -un) to run nvsm -- see docs/nvsm.md. A root shell via 'sudo -s' does not imply this: the grant is per-command." ;;
		*"must have a tty"*|*"no tty present"*)
			echo "ERROR: sudo requires a tty on this node and a batch task has none. The grant is fine; add 'Defaults:$(id -un) !requiretty' next to it." ;;
		*"command not found"*)
			echo "ERROR: nvsm is not on sudo's secure_path -- grant the absolute path 'command -v nvsm' reports on this node." ;;
		*"matching definition file"*|*"Failed to initialize NVSM"*)
			echo "ERROR: nvsm has no platform definition file for this node and never initialized. Sudo and the hardware are both fine -- this is NVSM platform support, and nvsm is DGX only. If this is not a DGX system, drop nvsm from benchmarks= in actions/launch_job.sh; it is not in the default list. If it is, set autogenerate_pdf in /etc/nvsm/nvsm.config in the software image. See docs/nvsm.md." ;;
		*)
			echo "ERROR: '${NVSM[*]} show version' failed (exit $rc). This is not a sudoers failure -- read the output below." ;;
	esac
	printf '%s\n' "$preflight"
	echo FAIL
	exit 0
fi

srun --ntasks-per-node=1 "${NVSM[@]}" stress-test --force --duration="${STRESS_SECONDS}"

## Follow-on health summary for the same node
srun --ntasks-per-node=1 "${NVSM[@]}" show health


## ------------- parse info starts here ----------- ##
## `nvsm show health` ends in a health summary. Requiring it is what proves
## both srun steps got far enough to report -- the sudo pre-check above only
## covers a missing grant, not an nvsm that starts and then dies mid-stress.
## The error grep alone would call that empty output a pass.

summary=$(grep -icE "Health Summary|System Status" "$RESULT_FILE")
status=$(grep -iE "fail|unhealthy|error|srun: error" "$RESULT_FILE")

if [[ -n "$RESULT_FILE" && -z "$status" && "$summary" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi

#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --gres=gpu:4
#SBATCH --ntasks-per-node=1
#SBATCH -t 0:50:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/nvsm.txt

## Steps inherit only what was explicitly requested; no --cpus-per-task, it
## implies --exact. See docs/reference/jobs.md#the-allocation-header.

## System-level GPU stress, run as a pre-burn-in health gate. DGX only, and not
## in the default BENCHMARKS list -- see docs/how-to/enable-nvsm.md.

# shellcheck disable=SC2034  # read by grepping this file, from actions/launch_job.sh
job_name=nvsm

## One limit per step, and they must sum to less than the walltime above.
## See docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
STRESS_TIMELIMIT=0:35:00
HEALTH_TIMELIMIT=0:05:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## What the STEP holds, which only a step can see. The passing line's wording is
## fixed -- verdict.sh greps this file. See docs/reference/jobs.md#preflight.
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

## Host binary, no container, and root-only -- hence sudo. `-n` because a batch
## task has no tty and a prompt would hang. Needs a NOPASSWD grant on every
## compute node; see docs/how-to/enable-nvsm.md.
if [[ $(id -u) -eq 0 ]]; then
	NVSM=(nvsm)
else
	NVSM=(sudo -n nvsm)
fi

## Fail before spending 20 minutes, and keep nvsm's own output: not every
## failure here is a missing grant. See docs/how-to/enable-nvsm.md.
preflight=$(srun --ntasks-per-node=1 "${NVSM[@]}" show version 2>&1)
rc=$?
if [[ $rc -ne 0 ]]; then
	case "$preflight" in
		*"password is required"*|*"not allowed to execute"*|*"may not run"*)
			echo "ERROR: no passwordless sudo grant for $(id -un) to run nvsm -- see docs/how-to/enable-nvsm.md. A root shell via 'sudo -s' does not imply this: the grant is per-command." ;;
		*"must have a tty"*|*"no tty present"*)
			echo "ERROR: sudo requires a tty on this node and a batch task has none. The grant is fine; add 'Defaults:$(id -un) !requiretty' next to it." ;;
		*"command not found"*)
			echo "ERROR: nvsm is not on sudo's secure_path -- grant the absolute path 'command -v nvsm' reports on this node." ;;
		*"matching definition file"*|*"Failed to initialize NVSM"*)
			echo "ERROR: nvsm has no platform definition file for this node and never initialized. Sudo and the hardware are both fine -- this is NVSM platform support, and nvsm is DGX only. If this is not a DGX system, drop nvsm from BENCHMARKS in SETTINGS; it is not in the default list. If it is, set autogenerate_pdf in /etc/nvsm/nvsm.config in the software image. See docs/how-to/enable-nvsm.md." ;;
		*)
			echo "ERROR: '${NVSM[*]} show version' failed (exit $rc). This is not a sudoers failure -- read the output below." ;;
	esac
	printf '%s\n' "$preflight"
	echo FAIL
	exit 0
fi

## Two steps, two exit statuses -- an nvsm that dies mid-stress still reaches
## the health summary, so neither status alone explains a FAIL.
srun --time="$STRESS_TIMELIMIT" --ntasks-per-node=1 "${NVSM[@]}" stress-test --force --duration="${STRESS_SECONDS}"
stress_rc=$?

## Follow-on health summary for the same node
srun --time="$HEALTH_TIMELIMIT" --ntasks-per-node=1 "${NVSM[@]}" show health
health_rc=$?


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is good is
## _v_gate_nvsm in verdict.sh. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.
## Both statuses go in the log: a FAIL with both at 0 came from the gate, which
## leaves no trace in this file.
echo "exit status: stress-test=$stress_rc show-health=$health_rc"
[[ "$stress_rc" -eq 0 && "$health_rc" -eq 0 ]] && echo PENDING || echo FAIL

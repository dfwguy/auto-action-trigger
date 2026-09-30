#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 1:10:00
#SBATCH --nice=20
## 20 is the sweep's tier. See docs/reference/jobs.md#queue-priority.
##SBATCH -o <RESULTS_DIR>/%N/ethr.txt

## No --gres: never touches a GPU. --exclusive is what makes the numbers mean
## anything -- a job sharing the node shares the NIC. See
## docs/reference/jobs.md#the-allocation-header.

## AI Factory Testing Plan: ethr -- SNT2 (Exhaustive)
## North-south throughput/latency on the in-band management and storage NICs,
## the paths NCCL's east-west RDMA traffic does not exercise.

## Job name is used in the status line. Edit grep for failures you're looking for
# shellcheck disable=SC2034
job_name=ethr

## Per-pass step limit. Two passes per interface, so adding an interface to
## IFACES means raising #SBATCH -t too. See
## docs/reference/jobs.md#two-time-limits-and-the-order-they-fire-in.
PASS_TIMELIMIT=0:30:00

## ------------- job info starts here ------------- ##

## Steps want neither set: srun aborts when the two disagree. See docs/reference/jobs.md#the-step-environment.
unset SLURM_CPUS_PER_TASK SLURM_TRES_PER_TASK SRUN_CPUS_PER_TASK

## Preflight -- what the STEP holds, which only a step can see. Wording is
## fixed; verdict.sh greps it. See docs/reference/jobs.md#preflight.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Host running `ethr -s`. Start the server side once, outside this job.
ETHR_SERVER=headnode
## Host-installed static Go binary, not a container -- see docs/explanation/containers.md.
ETHR_BIN=ethr
DURATION=30s

## Interfaces under test -- management and storage NICs, not the compute fabric
IFACES="enP22p3s0f0np0"

## Sticky across every pass: a later success must not overwrite an earlier
## failure. An interface with no address is not counted here -- nothing ran, so
## _v_gate_ethr catches it from the message below, whose wording is fixed.
rc=0

## Each pass is DURATION of traffic; the rest of PASS_TIMELIMIT is headroom for
## an ethr sitting in connection retries against an unreachable server.

for iface in $IFACES; do
    src_ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [[ -z "$src_ip" ]]; then
        echo "ethr: no IPv4 address on ${iface}"
        continue
    fi

    echo "===== ethr bandwidth ${iface} (${src_ip}) -> ${ETHR_SERVER} ====="
    srun --time="$PASS_TIMELIMIT" --ntasks-per-node=1 \
        "${ETHR_BIN}" -c "${ETHR_SERVER}" -t b -p tcp -d "${DURATION}" -n 8
    pass_rc=$?
    [[ "$pass_rc" -eq 0 ]] || rc=1

    echo "===== ethr latency ${iface} (${src_ip}) -> ${ETHR_SERVER} ====="
    srun --time="$PASS_TIMELIMIT" --ntasks-per-node=1 \
        "${ETHR_BIN}" -c "${ETHR_SERVER}" -t l -p tcp -d "${DURATION}"
    pass_rc=$?
    [[ "$pass_rc" -eq 0 ]] || rc=1
done


## ------------- parse info starts here ----------- ##

## Only whether the job ran is decided here; whether the result is good is
## verdict.sh's call. See docs/explanation/judging-benchmarks.md#where-a-pass-is-decided.

## Logged, not just left in the marker: a FAIL with a non-zero here is the
## job's own, a FAIL with `exit status: 0` came from the gate in verdict.sh.
echo "exit status: $rc"
[[ "$rc" -eq 0 ]] && echo PENDING || echo FAIL

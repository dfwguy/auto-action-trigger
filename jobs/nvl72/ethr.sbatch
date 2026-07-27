#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --mem=0
#SBATCH --ntasks-per-node=1
#SBATCH -t 1:00:00
##SBATCH -o /home/cmods/bringup/results/%N/ethr.txt

## Allocation. No --gres: this job never touches a GPU. --exclusive is what
## makes the numbers mean anything -- another job sharing the node shares the
## NIC, and its traffic lands in these latency figures. --mem=0 is stated
## because --exclusive does not imply it, and --cpus-per-task is deliberately
## absent: it implies --exact. See docs/benchmarks.md.

## AI Factory Testing Plan: ethr -- SNT2 (Exhaustive)
## North-south throughput/latency on the in-band management and storage NICs
## (ConnectX / BlueField). Characterizes paths NCCL does not exercise.
## Distinct from perftest/NCCL, which target east-west RDMA traffic.

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=ethr

## ------------- job info starts here ------------- ##

## Preflight -- what the STEP actually holds, asked from inside a step. The
## job's AllocTRES cannot answer that: a step is a different cgroup, and
## --exclusive grants the job resources a step does not inherit unless they
## were named. The passing line's wording is fixed -- the parse block below and
## verdict.sh grep this same file. See example.sbatch for the full reasoning.
srun --ntasks=1 bash -c '
    echo "preflight: $(hostname) cores=$(nproc)/${SLURM_CPUS_ON_NODE}"
    [[ "$(nproc)" -ge "${SLURM_CPUS_ON_NODE:-1}" ]]' || {
    echo "preflight: the step did not receive the whole node -- see above"
    echo FAIL
    exit 0
}

## Host running `ethr -s` (headnode or a storage-network endpoint).
## Start the server side once, outside this job:  ethr -s
ETHR_SERVER=headnode
## ethr is a single static Go binary -- install it on the host from
## github.com/microsoft/ethr rather than containerizing it.
ETHR_BIN=ethr
DURATION=30s

## Interfaces under test -- management and storage NICs, not the compute fabric
IFACES="enP22p3s0f0np0"

for iface in $IFACES; do
    src_ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    if [[ -z "$src_ip" ]]; then
        echo "ethr: no IPv4 address on ${iface}"
        continue
    fi

    echo "===== ethr bandwidth ${iface} (${src_ip}) -> ${ETHR_SERVER} ====="
    srun --ntasks-per-node=1 \
        "${ETHR_BIN}" -c "${ETHR_SERVER}" -t b -p tcp -d "${DURATION}" -n 8

    echo "===== ethr latency ${iface} (${src_ip}) -> ${ETHR_SERVER} ====="
    srun --ntasks-per-node=1 \
        "${ETHR_BIN}" -c "${ETHR_SERVER}" -t l -p tcp -d "${DURATION}"
done


## ------------- parse info starts here ----------- ##

results=$(grep -cE "Bandwidth|Latency" "$RESULT_FILE")
errors=$(grep -iE "unable to|connection refused|no route to host|error|no IPv4" "$RESULT_FILE")

if [[ -z "$errors" && "$results" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi

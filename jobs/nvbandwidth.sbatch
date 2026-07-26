#!/bin/bash
#SBATCH -p defq
#SBATCH -N 1
#SBATCH --exclusive
#SBATCH --gpus-per-node=4
#SBATCH -t 0:45:00
##SBATCH -o /home/cmods/bringup/results/%N/nvbandwidth.txt

## AI Factory Testing Plan: nvbandwidth -- SNT2 (Hybrid, TTM, Exhaustive)
## Per-GPU HBM, PCIe, and NVLink/NVSwitch bandwidth. Surfaces PCIe width/speed
## negotiation faults (x8 instead of x16) and HBM channel failures that DCGM
## does not report as explicit bandwidth numbers.
##
## Follows incubation/nvbandwidth-single-node-mop.md in the validation-mops
## repo. Adjust --gpus-per-node for the platform (4 for GB200, typically 8 for
## HGX H100/H200/B200).

## Job name is used in the status line. Edit grep for failures you're looking for
job_name=nvbandwidth

## ------------- job info starts here ------------- ##

## NOT ENABLED BY DEFAULT -- no public upstream image exists. Run
## `./build_containers.sh nvbandwidth` on the headnode to produce the image
## below, then add this job to the benchmarks= list in actions/launch_job.sh.
## See BUILD_CONTAINERS.md.
##
## The image is architecture-specific -- that is a CPU split, not a GPU
## generation one. Grace/Vera are ARM; Intel/AMD hosts use the x86 build.
## /tmp/containers is the node-local copy rsync'd by actions/file_copy.sh;
## the shared directory is the fallback until that rsync lands.
IMG=nvbandwidth-v0.9-$(uname -m | sed 's/aarch64/arm/;s/x86_64/x86/').sqsh
CONT=/tmp/containers/$IMG
[[ -f "$CONT" ]] || CONT=/home/cmods/bringup/containers/$IMG
## Registry alternative -- needs enroot credentials for the private NGC org on
## every compute node:
#case "$(uname -m)" in
#    aarch64) CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-arm ;;
#    x86_64)  CONT=docker://nvcr.io#0948245400141054/nvbandwidth-single-node:v0.9-x86 ;;
#esac

unset CUDA_VISIBLE_DEVICES

## Full default suite (33 tests) per the MOP reference command. The plan calls
## out device_to_device_memcpy_read_ce,
## device_to_device_bidirectional_memcpy_read_ce, host_to_device_memcpy_ce,
## device_to_host_memcpy_ce, and device_local_copy -- all included in the
## default suite. For triage, list with `nvbandwidth -l` and add -t <test>.
srun --export=ALL --cpu-bind=none --mem-bind=none --ntasks-per-node=1 \
                --container-image="${CONT}" \
                nvbandwidth


## ------------- parse info starts here ----------- ##
## MOP section 6.2 cross-cutting failure criteria -- platform-independent:
##   - any COEFFICIENT_OF_VARIATION > 0.02 (run-to-run instability)
##   - any N/A where a peer transfer was expected (missing GPU or P2P route)
##   - tool error / non-zero exit
## The per-test SUM thresholds in MOP section 6.1 are platform-specific (the
## published table is the GB200 4-GPU baseline) -- add them here once the
## baseline for this platform is established.

sums=$(grep -cE "^SUM " "$RESULT_FILE")
errors=$(grep -iE "error|not supported|waived|N/A|srun: error" "$RESULT_FILE")
unstable=$(awk '/COEFFICIENT_OF_VARIATION/ {v=$NF+0; if (v > 0.02) print}' "$RESULT_FILE")

if [[ -z "$errors" && -z "$unstable" && "$sums" -gt 0 ]];
then
	echo DONE
else
	echo FAIL
fi

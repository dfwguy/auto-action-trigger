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

## Published as architecture-specific images -- select by CPU arch, not GPU
## generation. Grace/Vera are ARM; Intel/AMD hosts use the x86 image.
##   ARM: nvcr.io/0948245400141054/nvbandwidth-single-node:v0.9-arm
##   x86: nvcr.io/0948245400141054/nvbandwidth-single-node:v0.9-x86
## Import once to the shared container dir (MOP section 4). Single-arch sites
## may collapse both to a single nvbandwidth.sqsh.
case "$(uname -m)" in
    aarch64) CONT=/home/cmods/bringup/containers/nvbandwidth-arm.sqsh ;;
    x86_64)  CONT=/home/cmods/bringup/containers/nvbandwidth-x86.sqsh ;;
    *)       echo "nvbandwidth: unsupported architecture $(uname -m)"; exit 1 ;;
esac

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

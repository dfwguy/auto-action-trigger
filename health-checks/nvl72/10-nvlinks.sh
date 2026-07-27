#!/bin/bash
# banner: #########INFO: Check NVLINK status (Expected: 72 links are up)

nvidia-smi nvlink -s | grep '5[0-9].* GB/s' | wc -l
nvidia-smi --format=csv --query-gpu gpu_bus_id,fabric.state,fabric.status

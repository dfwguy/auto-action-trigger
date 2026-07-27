#!/bin/bash
# banner: ########INFO: Check GPU basic

nvidia-smi --format=csv \
  --query-gpu gpu_bus_id,gpu_name,vbios_version,pstate,enforced.power.limit,\
ecc.errors.uncorrected.aggregate.total,remapped_rows.failure,remapped_rows.uncorrectable,remapped_rows.pending

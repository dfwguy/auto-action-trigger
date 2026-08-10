#!/bin/bash
# banner: ########INFO: Check OFED version (Expected: all nodes the same)

if command -v ofed_info >/dev/null 2>&1; then
  ofed_info -s | tr -d ':'
elif [ -r /sys/module/mlx5_core/version ]; then
  echo "no ofed_info; mlx5_core $(cat /sys/module/mlx5_core/version)"
else
  echo 'no ofed_info and no mlx5_core module -- OFED version not reported'
fi

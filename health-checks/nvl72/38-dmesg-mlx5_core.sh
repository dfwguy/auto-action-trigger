#!/bin/bash
# banner: ########INFO: Check dmesg - mlx5_core.*Health issue observed.*ERROR (Expected: No mlx5_core Health issue observed errors)

sudo -n dmesg --since "8 hour ago" | grep "mlx5_core.*Health issue observed.*ERROR" | wc -l

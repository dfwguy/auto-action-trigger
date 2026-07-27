#!/bin/bash
# banner: ########INFO: Check NUMA_BALANCING and THP (Expected: NUMA_BALANCING=0 and THP=madvise)

sysctl kernel.numa_balancing
cat /sys/kernel/mm/transparent_hugepage/enabled

#!/bin/bash
# banner: ########INFO: Check IB devices status (Expected: All up and active)

ibstatus | grep -E 'Infiniband|state:' | paste - - - | sort -t'_' -k2n

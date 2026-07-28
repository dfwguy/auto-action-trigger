#!/bin/bash
# banner: #########INFO: Check P2P pcie capability status (Expected: All GPU are OK on RTX/L20)

nvidia-smi topo -p2p p 2>&1 | grep 'GPU[0-9].*OK' || true

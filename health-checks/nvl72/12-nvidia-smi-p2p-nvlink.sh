#!/bin/bash
# banner: #########INFO: Check P2P nvlink capability status (Expected: All GPU are OK on GBXX/BXX/HXX)

nvidia-smi topo -p2p n 2>&1 | grep 'GPU[0-9].*OK' || true

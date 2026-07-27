#!/bin/bash
# banner: #########INFO: Check NVLINK BER (Expected: no output)

nvidia-smi nvlink -e | grep BER | grep -v 15e-255 || true

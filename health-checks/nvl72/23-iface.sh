#!/bin/bash
# banner: ########INFO: Check IFace device status (Expected: all nodes use the same interface connect to default gateway)

ip r sh | grep default | grep -o "dev.*" | cut -f2 -d' '

#!/bin/bash
# banner: ########INFO: Check Memory

sudo -n dmidecode -t memory | grep -P '\tVolatile Size:' | tr -d '\t' | sort | uniq -c

#!/bin/bash
# banner: ########INFO: Check Memory

dmidecode -t memory | grep -P '\tVolatile Size:' | tr -d '\t' | sort | uniq -c

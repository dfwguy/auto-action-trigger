#!/bin/bash
# banner: ########INFO: Check PCIe LnkCap+LnkStat (Expected: No issue found, but on BXX/HXX xx:xx.{0..3} shown is expected)

if [ "$(uname -m)" == x86_64 ]; then
  lspci -d 15b3: -nn | awk '{print $1}' \
    | while read -r i; do
        cnt=$(lspci -s "$i" -vvv \
          | grep -e LnkCap: -e LnkSta: \
          | grep -o "Speed.*" \
          | awk -F',' '{print $1, $2}' \
          | tr -s ' ' \
          | sort | uniq -c | wc -l)
        if [ "$cnt" -ne 1 ]; then
          echo "$i"
        fi
      done
elif [ "$(uname -m)" == aarch64 ]; then
  lspci -d 15b3: -nn | grep controller | awk '{print $1}' \
    | while read -r i; do
        cnt=$(lspci -s "$i" -vvv \
          | grep -e LnkCap: -e LnkSta: \
          | grep -o "Speed.*" \
          | awk -F',' '{print $1, $2}' \
          | tr -s ' ' \
          | sort | uniq -c | wc -l)
        if [ "$cnt" -ne 1 ]; then
          echo "$i"
        fi
      done
fi

#!/bin/bash
# banner: ########INFO: Check Enroot runtime directory (Expected: ENROOT_RUNTIME_PATH Writable)

a=$(grep ENROOT_RUNTIME_PATH /etc/enroot/enroot.conf 2>/dev/null | grep -o '/.*')
if [ -n "${a}" ]; then
  mkdir -p "${a}" 2>/dev/null
  if touch "${a}/test" &>/dev/null; then
    echo "${a} is writable"
    rm -f "${a}/test"
  else
    echo "${a} is read-only"
  fi
else
  echo "ENROOT_RUNTIME_PATH not set"
fi

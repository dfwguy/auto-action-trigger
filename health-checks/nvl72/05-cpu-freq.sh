#!/bin/bash
# banner: ########INFO: Check CPU Frequency (Expected: CPUs are in performance mode and frequency all above 1800 MHz)

if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
  cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor | sort | uniq -c
else
  echo "CPU frequency scaling not supported" 
fi

if [ "$(uname -m)" == x86_64 ]; then
  cpupower monitor -m Mperf | awk '/Mperf/,/^$/{print $0}' | grep -v -e Mperf -e Freq \
    | awk -F '|' '{print $1,$NF}' | sort -n \
    | awk '{
        key=$1; val=$2;
        sum[key]+=val; count[key]++
      } END {
        for (k in sum) {
          avg=sum[k]/count[k];
          status=(avg > 1800 ? "PASS" : "FAIL");
          printf "CPU Freq: Socket%s %s\n", k, status
        }
      }' | paste -s -d','
fi

if [ "$(uname -m)" == aarch64 ]; then
  m=
  if [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_cur_freq ]; then
    m=cpuinfo_cur_freq
  elif [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    m=scaling_cur_freq
  fi
  if [ -n "${m}" ]; then
    # Guard on the directory: with no NUMA sysfs the glob stays unexpanded.
    for d in /sys/devices/system/node/node*/; do
      [ -d "$d" ] || continue
      i=${d%/}; i=${i##*/}; i=${i#node}
      cat /sys/devices/system/node/node${i}/cpu*/cpufreq/$m 2>/dev/null \
      | awk -v node=$i 'BEGIN{sum=0}{
          sum+=$1
        } END {
          if (NR>0) {
            ret=int(sum/NR/1000);
            if (ret>1800) {
              printf "%s freq PASS\n", node
            } else {
              printf "%s freq FAILED\n", node
            }
          }
        }'
    done
  else
    echo "CPU frequency info not available"
  fi
fi

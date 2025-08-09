#!/bin/bash
# Sends an alert if any disk partition is over 90% full

EMAIL="admin@example.com"
df -h | awk 'NR>1 {print $5 " " $6}' | while read output; do
  usep=$(echo $output | awk '{ print $1}' | sed 's/%//g')
  partition=$(echo $output | awk '{ print $2 }')
  if [ $usep -ge 90 ]; then
    echo "Running out of space \"$partition ($usep%)\" on $(hostname)" | mail -s "Disk Space Alert: $partition" $EMAIL
  fi
done

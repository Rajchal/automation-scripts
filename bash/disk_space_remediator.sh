#!/bin/bash

# Deletes the oldest files in /var/log if disk usage > 85%
THRESHOLD=85
LOGDIR="/var/log"

USAGE=$(df "$LOGDIR" | awk 'NR==2{gsub("%","",$5); print $5}')

if [ "$USAGE" -gt "$THRESHOLD" ]; then
  echo "Disk usage in $LOGDIR is $USAGE%. Deleting oldest files..."
  find "$LOGDIR" -type f -printf '%T+ %p\n' | sort | head -n 10 | awk '{print $2}' | xargs rm -f
fi

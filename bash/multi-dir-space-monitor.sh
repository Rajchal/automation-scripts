#!/bin/bash

DIRS=("/" "/var" "/home")
THRESHOLD=80
EMAIL="admin@example.com"

for d in "${DIRS[@]}"; do
  USAGE=$(df -h "$d" | awk 'NR==2 {gsub("%","",$5); print $5}')
  if [ "$USAGE" -gt "$THRESHOLD" ]; then
    echo "ALERT: $d usage at $USAGE%" | mail -s "Disk space alert on $(hostname)" "$EMAIL"
  fi
done

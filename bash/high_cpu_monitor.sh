#!/bin/bash

THRESHOLD=80
EMAIL="admin@example.com"

ps -eo pid,comm,%cpu --sort=-%cpu | awk -v th=$THRESHOLD 'NR>1 && $3>th {print $0}' | while read line; do
  echo "High CPU usage detected: $line" | mail -s "High CPU Alert" "$EMAIL"
done

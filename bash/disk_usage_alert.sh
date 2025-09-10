#!/bin/bash
# disk_usage_alert.sh
# Alerts if disk usage exceeds a threshold
THRESHOLD=80
EMAIL="admin@example.com"
usage=$(df -h / | grep '/' | awk '{print $5}' | sed 's/%//g')
if [ "$usage" -gt "$THRESHOLD" ]; then
    echo "Disk usage is above $THRESHOLD%. Current usage: $usage%" | mail -s "Disk Usage Alert" $EMAIL
fi

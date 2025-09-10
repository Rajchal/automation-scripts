#!/bin/bash
# cpu_usage_alert.sh
# Alerts if CPU usage exceeds a threshold
THRESHOLD=85
EMAIL="admin@example.com"
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
CPU_USAGE_INT=${CPU_USAGE%.*}
if [ "$CPU_USAGE_INT" -gt "$THRESHOLD" ]; then
    echo "CPU usage is above $THRESHOLD%. Current usage: $CPU_USAGE%" | mail -s "CPU Usage Alert" $EMAIL
fi

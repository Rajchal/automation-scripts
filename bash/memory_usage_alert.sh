#!/bin/bash
# memory_usage_alert.sh
# Alerts if memory usage exceeds a threshold
THRESHOLD=85
EMAIL="admin@example.com"
MEM_USAGE=$(free | grep Mem | awk '{printf("%.0f", $3/$2 * 100.0)}')
if [ "$MEM_USAGE" -gt "$THRESHOLD" ]; then
    echo "Memory usage is above $THRESHOLD%. Current usage: $MEM_USAGE%" | mail -s "Memory Usage Alert" $EMAIL
fi

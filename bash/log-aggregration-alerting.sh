#!/bin/bash

# Bash script to aggregate logs and send alerts
set -e

LOG_DIR="/var/log/myapp"
AGGREGATED_LOG="/tmp/aggregated.log"
ALERT_EMAIL="admin@example.com"

echo "Aggregating logs..."

# Aggregate logs
cat $LOG_DIR/*.log > $AGGREGATED_LOG

# Check for critical errors
if grep -q "CRITICAL" $AGGREGATED_LOG; then
  echo "Critical error found in logs! Sending alert..."
  mail -s "Critical Error Alert" $ALERT_EMAIL < $AGGREGATED_LOG
else
  echo "No critical errors found."
fi

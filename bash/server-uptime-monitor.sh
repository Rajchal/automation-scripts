#!/bin/bash

# Bash script to monitor server uptime and send notifications
set -e

THRESHOLD=5 # Threshold in minutes
ALERT_EMAIL="admin@example.com"

echo "Monitoring server uptime..."

# Get uptime in minutes
UPTIME=$(awk '{print int($1 / 60)}' /proc/uptime)

# Check if uptime is below threshold
if [[ "$UPTIME" -lt "$THRESHOLD" ]]; then
  echo "Server uptime is below threshold! Sending alert..."
  echo "Server uptime is only $UPTIME minutes. Check the server immediately." | mail -s "Server Uptime Alert" "$ALERT_EMAIL"
else
  echo "Server uptime is healthy: $UPTIME minutes."
fi

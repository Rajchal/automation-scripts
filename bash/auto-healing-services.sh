#!/bin/bash

# Bash script to monitor and restart failed services
set -e

echo "Starting service auto-healing monitor..."

# List of services to monitor
SERVICES=("nginx" "mysql" "redis")

# Monitor services
while true; do
  for SERVICE in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet "$SERVICE"; then
      echo "Service $SERVICE is down! Restarting..."
      systemctl restart "$SERVICE"
      echo "Service $SERVICE restarted successfully!"
    fi
  done
  sleep 30
done

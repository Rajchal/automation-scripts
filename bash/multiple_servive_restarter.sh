#!/bin/bash
# Checks and restarts a list of critical services if not running

SERVICES=("nginx" "mysql" "docker" "redis" "sshd")
for svc in "${SERVICES[@]}"; do
  systemctl is-active --quiet "$svc" || {
    echo "Restarting $svc..."
    systemctl restart "$svc"
  }
done

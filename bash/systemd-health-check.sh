#!/bin/bash

SERVICES=("nginx" "docker" "sshd")
for svc in "${SERVICES[@]}"; do
  systemctl is-active --quiet "$svc"
  if [ $? -ne 0 ]; then
    echo "Service $svc is not running. Restarting..."
    systemctl restart "$svc"
    sleep 2
    systemctl is-active --quiet "$svc" && echo "$svc restarted successfully" || echo "Failed to restart $svc"
  else
    echo "$svc is running."
  fi
done

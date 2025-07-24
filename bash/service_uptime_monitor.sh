#!/bin/bash

SERVICES=("nginx" "docker" "sshd")
RESTART_LOG="service_restart.log"

for svc in "${SERVICES[@]}"; do
  systemctl is-active --quiet "$svc"
  if [ $? -ne 0 ]; then
    echo "$(date): $svc is down, restarting..." | tee -a "$RESTART_LOG"
    systemctl restart "$svc"
  else
    echo "$(date): $svc is running."
  fi
done

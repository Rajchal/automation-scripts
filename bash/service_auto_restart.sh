#!/bin/bash
# service_auto_restart.sh
# Restarts a service if it is down
SERVICE="nginx"
if ! systemctl is-active --quiet $SERVICE; then
    echo "$SERVICE is down. Restarting..."
    systemctl restart $SERVICE
fi

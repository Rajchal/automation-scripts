#!/bin/bash
# service_status_report.sh
# Reports the status of critical services and sends an alert if any are inactive
SERVICES=("nginx" "mysql" "docker")
EMAIL="admin@example.com"
for SERVICE in "${SERVICES[@]}"; do
    if ! systemctl is-active --quiet $SERVICE; then
        echo "$SERVICE is inactive on $(hostname)" | mail -s "Service Status Alert: $SERVICE" $EMAIL
    fi
done

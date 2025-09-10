#!/bin/bash
# service_uptime_report.sh
# Reports the uptime of critical services and sends an alert if any have restarted within the last 24 hours
SERVICES=("nginx" "mysql" "docker")
EMAIL="admin@example.com"
for SERVICE in "${SERVICES[@]}"; do
    uptime=$(systemctl show -p ActiveEnterTimestamp $SERVICE | cut -d'=' -f2)
    if [ -n "$uptime" ]; then
        uptime_seconds=$(date --date="$uptime" +%s)
        now_seconds=$(date +%s)
        diff_hours=$(( (now_seconds - uptime_seconds) / 3600 ))
        if [ "$diff_hours" -lt 24 ]; then
            echo "$SERVICE was restarted within the last 24 hours on $(hostname)" | mail -s "Service Uptime Alert: $SERVICE" $EMAIL
        fi
    fi
done

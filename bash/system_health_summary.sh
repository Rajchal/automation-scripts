#!/bin/bash
# system_health_summary.sh
# Generates a summary of system health and sends it via email
EMAIL="admin@example.com"
REPORT="System Health Summary for $(hostname) on $(date)\n\n"
REPORT+="Disk Usage:\n$(df -h)\n\n"
REPORT+="CPU Usage:\n$(top -bn1 | grep 'Cpu(s)')\n\n"
REPORT+="Memory Usage:\n$(free -h)\n\n"
REPORT+="Active Services:\n$(systemctl list-units --type=service --state=active | head -20)\n\n"
echo -e "$REPORT" | mail -s "System Health Summary" $EMAIL

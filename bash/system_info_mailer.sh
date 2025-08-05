#!/bin/bash

# Gathers basic system info and emails it
EMAIL="admin@example.com"
REPORT="/tmp/sysinfo_$(date +%F).txt"

{
  echo "Hostname: $(hostname)"
  echo "Uptime: $(uptime -p)"
  echo "Disk Usage:"
  df -h
  echo "Memory Usage:"
  free -h
  echo "Top Processes:"
  ps aux --sort=-%mem | head -n 10
} > "$REPORT"

mail -s "System Info Report for $(hostname)" "$EMAIL" < "$REPORT"

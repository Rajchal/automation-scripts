#!/bin/bash
# network_latency_report.sh
# Checks network latency to a target host and sends an alert if latency exceeds a threshold
TARGET="8.8.8.8"
THRESHOLD=100
EMAIL="admin@example.com"
LATENCY=$(ping -c 4 $TARGET | tail -1 | awk -F '/' '{print $5}')
LATENCY_INT=${LATENCY%.*}
if [ "$LATENCY_INT" -gt "$THRESHOLD" ]; then
    echo "Network latency to $TARGET is above $THRESHOLD ms. Current: $LATENCY ms" | mail -s "Network Latency Alert" $EMAIL
fi

#!/bin/bash
# largest_files_report.sh
# Reports the largest files in a specified directory and sends an alert if any exceed a size threshold
TARGET_DIR="/var/log"
THRESHOLD_MB=500
EMAIL="admin@example.com"
largest_files=$(find $TARGET_DIR -type f -exec du -m {} + | sort -nr | head -10)
alert_files=$(echo "$largest_files" | awk -v threshold=$THRESHOLD_MB '$1 > threshold')
if [ -n "$alert_files" ]; then
    echo -e "Files exceeding $THRESHOLD_MB MB in $TARGET_DIR:\n$alert_files" | mail -s "Large Files Alert" $EMAIL
fi

#!/bin/bash
# log_error_report.sh
# Scans system logs for errors in the last 24 hours and sends an alert if any are found
EMAIL="admin@example.com"
ERRORS=$(journalctl --since "1 day ago" -p err)
if [ -n "$ERRORS" ]; then
    echo -e "System errors in the last 24 hours:\n$ERRORS" | mail -s "System Error Report" $EMAIL
fi

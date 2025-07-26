#!/bin/bash

TARGET="/tmp"
DAYS=14
EMAIL="admin@example.com"
REPORT="/tmp/deleted_files_report_$(date +%F).txt"

echo "Deleting files in $TARGET older than $DAYS days..." > "$REPORT"
find "$TARGET" -type f -mtime +$DAYS -print -delete >> "$REPORT"

mail -s "Old files deleted on $(hostname)" "$EMAIL" < "$REPORT"

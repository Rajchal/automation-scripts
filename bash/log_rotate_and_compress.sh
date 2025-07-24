#!/bin/bash

LOG_DIR="/var/log/custom"
ARCHIVE_DIR="/var/log/archive"
DAYS=7

mkdir -p "$ARCHIVE_DIR"

echo "Rotating and compressing logs older than $DAYS days in $LOG_DIR..."

find "$LOG_DIR" -type f -mtime +$DAYS -exec gzip {} \; -exec mv {}.gz "$ARCHIVE_DIR" \;

echo "Old logs compressed and moved to $ARCHIVE_DIR."

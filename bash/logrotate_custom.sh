#!/bin/bash
# Rotates, compresses, and cleans up log files in /var/log/custom

LOGDIR="/var/log/custom"
ARCHDIR="$LOGDIR/archive"
RETENTION=30

mkdir -p "$ARCHDIR"
find "$LOGDIR" -type f -name "*.log" -mtime +7 -exec gzip {} \; -exec mv {}.gz "$ARCHDIR" \;
find "$ARCHDIR" -type f -mtime +$RETENTION -delete

#!/bin/bash

LOGDIR="/var/log/myapp"
ARCHDIR="/var/log/myapp/archive"
DAYS=7

mkdir -p "$ARCHDIR"
find "$LOGDIR" -maxdepth 1 -type f -name "*.log" -mtime +$DAYS -exec gzip {} \; -exec mv {}.gz "$ARCHDIR" \;
find "$ARCHDIR" -type f -mtime +60 -delete

echo "Old logs archived and ancient archives pruned."

#!/bin/bash

SRC="/home/"
DEST="/backup/home/"
EXCLUDES="/etc/rsync_excludes.txt"
LOG="/var/log/rsync_backup_$(date +%F).log"

mkdir -p "$DEST"
echo "Starting rsync backup..." | tee "$LOG"
rsync -avh --delete --exclude-from="$EXCLUDES" "$SRC" "$DEST" | tee -a "$LOG"
echo "Rsync backup completed." | tee -a "$LOG"

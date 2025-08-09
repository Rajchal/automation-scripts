#!/bin/bash
# Rsyncs multiple folders to a backup server

FOLDERS="/etc /var/www /home"
DEST="backupserver:/backup/$(hostname)/"
for f in $FOLDERS; do
  rsync -a "$f" "$DEST"
done

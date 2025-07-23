#!/bin/bash

SRC="/etc"
DEST="/backup"
DATE=$(date +%F)
RETENTION_DAYS=14

mkdir -p "$DEST"
tar czf "$DEST/etc-backup-$DATE.tar.gz" "$SRC"

echo "Backup completed: $DEST/etc-backup-$DATE.tar.gz"

# Remove old backups
find "$DEST" -name 'etc-backup-*.tar.gz' -mtime +$RETENTION_DAYS -exec rm -v {} \;

echo "Old backups older than $RETENTION_DAYS days removed."

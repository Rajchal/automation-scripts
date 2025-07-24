#!/bin/bash

SRC="/etc"
DEST="/backup"
DATE=$(date +%F)
BACKUP="$DEST/etc-backup-$DATE.tar.gz"
CHECKSUM_FILE="$BACKUP.sha256"

mkdir -p "$DEST"
tar czf "$BACKUP" "$SRC"
sha256sum "$BACKUP" > "$CHECKSUM_FILE"

echo "Backup created: $BACKUP"
echo "Checksum saved: $CHECKSUM_FILE"

# Verify the backup
echo "Verifying backup integrity..."
if sha256sum -c "$CHECKSUM_FILE"; then
  echo "Backup integrity: OK"
else
  echo "Backup integrity: FAILED"
fi

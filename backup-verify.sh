#!/bin/bash
BACKUP_DIR="/backups"
for file in $BACKUP_DIR/*.tar.gz; do
    if ! tar -tzf $file > /dev/null; then
        echo "Corrupted backup file: $file"
    fi
done

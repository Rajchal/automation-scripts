#!/bin/bash

DB_USER="root"
DB_PASS="changeme"
BACKUP_DIR="/var/backups/mysql"
DATE=$(date +%F)
RETENTION=7

mkdir -p "$BACKUP_DIR"
mysqldump -u$DB_USER -p$DB_PASS --all-databases | gzip > "$BACKUP_DIR/all-databases-$DATE.sql.gz"

find "$BACKUP_DIR" -type f -mtime +$RETENTION -name "*.sql.gz" -exec rm -v {} \;

echo "MySQL backup completed and old backups pruned."

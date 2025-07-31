#!/bin/bash

DB="your_db"
USER="root"
PASS="password"
BKPDIR="/var/backups/mysql"
DATE=$(date +%F)
S3BUCKET="s3://your-bucket/db-backups"

mkdir -p "$BKPDIR"
mysqldump -u"$USER" -p"$PASS" "$DB" | gzip > "$BKPDIR/$DB-$DATE.sql.gz"
aws s3 cp "$BKPDIR/$DB-$DATE.sql.gz" "$S3BUCKET/"
echo "Backup and upload complete for $DB on $DATE"

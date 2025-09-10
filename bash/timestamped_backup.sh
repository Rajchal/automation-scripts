#!/bin/bash
# timestamped_backup.sh
# Creates a timestamped backup of a directory
SOURCE_DIR="/var/www/html"
BACKUP_DIR="/home/rajchal/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
mkdir -p $BACKUP_DIR
tar -czf $BACKUP_DIR/html_backup_$TIMESTAMP.tar.gz $SOURCE_DIR

#!/bin/bash
# Syncs a local directory to an S3 bucket and cleans up old local files

SRC="/data/backups"
BUCKET="s3://your-bucket/backups"
RETENTION=14

aws s3 sync "$SRC" "$BUCKET"
find "$SRC" -type f -mtime +$RETENTION -delete

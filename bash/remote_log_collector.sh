#!/bin/bash

HOSTS_FILE="hosts.txt"
REMOTE_LOG="/var/log/syslog"
LOCAL_DIR="/var/log/remote_logs"
mkdir -p "$LOCAL_DIR"
DATE=$(date +%F)

while read host; do
  scp "$host:$REMOTE_LOG" "$LOCAL_DIR/${host}_syslog_$DATE.log"
done < "$HOSTS_FILE"

find "$LOCAL_DIR" -type f -mtime +30 -delete
echo "Logs collected and old logs purged."

#!/bin/bash

# Blocks IPs with more than 1000 requests in the last hour
LOG="/var/log/nginx/access.log"
THRESHOLD=1000
BLOCK_FILE="/etc/nginx/blockips.conf"

awk -v date="$(date +"%d/%b/%Y:%H")" '$4 ~ date {print $1}' "$LOG" | sort | uniq -c | awk -v t=$THRESHOLD '$1 > t {print "deny "$2";"}' > "$BLOCK_FILE"

if [ -s "$BLOCK_FILE" ]; then
  echo "Blocking IPs:"
  cat "$BLOCK_FILE"
  nginx -s reload
fi

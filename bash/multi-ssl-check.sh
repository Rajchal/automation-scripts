#!/bin/bash

HOSTS=("example.com" "github.com" "yourdomain.com")
DAYS=30

for host in "${HOSTS[@]}"; do
  expiry=$(echo | openssl s_client -servername "$host" -connect "$host":443 2>/dev/null | openssl x509 -noout -dates | grep notAfter | cut -d= -f2)
  exp_ts=$(date -d "$expiry" +%s)
  now_ts=$(date +%s)
  days_left=$(( (exp_ts - now_ts) / 86400 ))
  echo "$host SSL expires in $days_left days ($expiry)"
  if [ "$days_left" -lt "$DAYS" ]; then
    echo "WARNING: $host SSL certificate expires in $days_left days!"
  fi
done

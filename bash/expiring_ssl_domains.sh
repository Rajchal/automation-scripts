#!/bin/bash

# Checks a list of domains for SSL certificate expiry within 15 days
DOMAINS=("example.com" "github.com")
ALERT_DAYS=15

for domain in "${DOMAINS[@]}"; do
  expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
  exp_ts=$(date -d "$expiry" +%s)
  now_ts=$(date +%s)
  days_left=$(( (exp_ts - now_ts) / 86400 ))
  if [ "$days_left" -le "$ALERT_DAYS" ]; then
    echo "Domain $domain certificate expires in $days_left days ($expiry)"
  fi
done

#!/bin/bash

DOMAINS=("example.com" "github.com")
ALERT_DAYS=30
EMAIL="admin@example.com"

for domain in "${DOMAINS[@]}"; do
    expiry=$(echo | openssl s_client -servername $domain -connect $domain:443 2>/dev/null | \
      openssl x509 -noout -enddate | cut -d= -f2)
    expiry_date=$(date -d "$expiry" +%s)
    now=$(date +%s)
    diff_days=$(( ($expiry_date - $now) / 86400 ))
    echo "$domain: expires in $diff_days days ($expiry)"
    if [ "$diff_days" -le "$ALERT_DAYS" ]; then
        echo "SSL certificate for $domain expires in $diff_days days!" | \
            mail -s "SSL Certificate Alert for $domain" "$EMAIL"
    fi
done

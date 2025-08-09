#!/bin/bash
# Checks SSL expiry for domains and emails a report if any expire soon

DOMAINS=("example.com" "github.com")
EMAIL="admin@example.com"
THRESHOLD=30

REPORT=$(mktemp)
for domain in "${DOMAINS[@]}"; do
  expiry=$(echo | openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
  days_left=$(( ( $(date -d "$expiry" +%s) - $(date +%s) ) / 86400 ))
  echo "$domain: $days_left days left ($expiry)" >> "$REPORT"
  if [ "$days_left" -le "$THRESHOLD" ]; then
    echo "ALERT: $domain SSL expires in $days_left days!" >> "$REPORT"
  fi
done
mail -s "SSL Certificate Expiry Report" "$EMAIL" < "$REPORT"
rm "$REPORT"

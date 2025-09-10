#!/bin/bash
# ssl_expiry_alert.sh
# Checks SSL certificate expiry for a domain and sends an alert if it is expiring soon
DOMAIN="example.com"
THRESHOLD=15
EMAIL="admin@example.com"
expiry_date=$(echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
expiry_seconds=$(date --date="$expiry_date" +%s)
current_seconds=$(date +%s)
days_left=$(( (expiry_seconds - current_seconds) / 86400 ))
if [ "$days_left" -le "$THRESHOLD" ]; then
    echo "SSL certificate for $DOMAIN expires in $days_left days!" | mail -s "SSL Expiry Alert for $DOMAIN" $EMAIL
fi

#!/bin/bash

# Bash script to check SSL certificate expiry
set -e

echo "Checking SSL certificate expiry..."

# Input domain
read -p "Enter the domain (e.g., example.com): " DOMAIN

# Get expiry date
EXPIRY_DATE=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -dates | grep "notAfter" | cut -d= -f2)

# Convert expiry date to epoch
EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
CURRENT_EPOCH=$(date +%s)

# Calculate days to expiry
DAYS_TO_EXPIRY=$(( (EXPIRY_EPOCH - CURRENT_EPOCH) / 86400 ))

if [[ "$DAYS_TO_EXPIRY" -le 30 ]]; then
  echo "SSL certificate for $DOMAIN is expiring in $DAYS_TO_EXPIRY days! Renew it soon."
else
  echo "SSL certificate for $DOMAIN is valid for $DAYS_TO_EXPIRY more days."
fi

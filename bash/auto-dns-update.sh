#!/bin/bash

# Bash script to automatically update DNS records using Cloudflare API
set -e

echo "Starting DNS record update..."

# Input variables
API_TOKEN="your-cloudflare-api-token"
ZONE_ID="your-cloudflare-zone-id"
RECORD_NAME="subdomain.example.com"
RECORD_TYPE="A"
NEW_IP=$(curl -s https://api.ipify.org)

# Fetch the DNS record ID
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=$RECORD_TYPE&name=$RECORD_NAME" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  | jq -r '.result[0].id')

# Update DNS record
curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$NEW_IP\",\"ttl\":1,\"proxied\":false}"

echo "DNS record updated to $NEW_IP"

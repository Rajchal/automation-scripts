#!/bin/bash
domain="example.com"
record_name="www"
ip=$(curl -s https://api.ipify.org)
curl -X PUT -H "Content-Type: application/json" -d "{\"data\":\"$ip\"}" "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id"

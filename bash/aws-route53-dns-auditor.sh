#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-route53-dns-auditor.log"
REPORT_FILE="/tmp/route53-dns-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOW_TTL_THRESHOLD="${ROUTE53_LOW_TTL_THRESHOLD:-60}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "Route53 DNS Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Low TTL threshold: ${LOW_TTL_THRESHOLD}s" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_zone() {
  local zone_id="$1"
  local zone_name="$2"
  local is_private="$3"

  echo "HostedZone: $zone_name ($zone_id) private=$is_private" >> "$REPORT_FILE"

  if [ "$is_private" = "false" ]; then
    send_slack_alert "Route53 Alert: Public hosted zone $zone_name ($zone_id) detected"
  fi

  # iterate record sets
  aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --output json 2>/dev/null | jq -c '.ResourceRecordSets[]?' | while read -r rr; do
    name=$(echo "$rr" | jq -r '.Name')
    type=$(echo "$rr" | jq -r '.Type')
    ttl=$(echo "$rr" | jq -r '.TTL // empty')
    alias=$(echo "$rr" | jq -c '.AliasTarget // empty')

    if [[ "$name" == \*.* ]]; then
      echo "  WILDCARD record: $name type=$type" >> "$REPORT_FILE"
      send_slack_alert "Route53 Alert: Wildcard record $name in zone $zone_name"
    fi

    if [ -n "$ttl" ] && [ "$ttl" != "null" ]; then
      if [ "$ttl" -lt "$LOW_TTL_THRESHOLD" ]; then
        echo "  LOW TTL: $name type=$type ttl=$ttl" >> "$REPORT_FILE"
        send_slack_alert "Route53 Alert: Low TTL ($ttl) for $name in $zone_name"
      fi
    fi

    if [ "$alias" != "empty" ]; then
      target=$(echo "$alias" | jq -r '.DNSName // ""')
      # flag S3 website alias (public website endpoints)
      if echo "$target" | grep -Eq "s3-website|s3-website.[a-z]"; then
        echo "  Alias to S3 website detected: $name -> $target" >> "$REPORT_FILE"
        send_slack_alert "Route53 Alert: Record $name in $zone_name aliases to S3 website endpoint ($target)"
      fi
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  zones_json=$(aws route53 list-hosted-zones --output json 2>/dev/null || echo '{"HostedZones":[]}')
  zones=$(echo "$zones_json" | jq -c '.HostedZones[]?')

  if [ -z "$zones" ]; then
    echo "No hosted zones found." >> "$REPORT_FILE"
    log_message "No Route53 hosted zones found"
    exit 0
  fi

  echo "$zones_json" | jq -c '.HostedZones[]?' | while read -r z; do
    zid=$(echo "$z" | jq -r '.Id' | sed 's|/hostedzone/||')
    zname=$(echo "$z" | jq -r '.Name')
    private=$(echo "$z" | jq -r '.Config.PrivateZone // false')
    check_zone "$zid" "$zname" "$private"
  done

  log_message "Route53 DNS audit written to $REPORT_FILE"
}

main "$@"

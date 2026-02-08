#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-s3-encryption-auditor.log"
REPORT_FILE="/tmp/s3-encryption-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS S3 Encryption & Config Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_bucket() {
  local b="$1"
  echo "Bucket: $b" >> "$REPORT_FILE"

  # Encryption
  if aws s3api get-bucket-encryption --bucket "$b" --output json >/dev/null 2>&1; then
    enc=$(aws s3api get-bucket-encryption --bucket "$b" --output json 2>/dev/null || echo '{}')
    echo "  Encryption: configured" >> "$REPORT_FILE"
  else
    echo "  Encryption: NOT CONFIGURED" >> "$REPORT_FILE"
    send_slack_alert "S3 Alert: Bucket $b has no default encryption configured"
  fi

  # Public access block
  pab=$(aws s3api get-public-access-block --bucket "$b" --output json 2>/dev/null || echo '{}')
  if [ -z "$pab" ] || [ "$(echo "$pab" | jq -r '.PublicAccessBlockConfiguration // empty')" = "" ]; then
    echo "  PublicAccessBlock: NOT CONFIGURED" >> "$REPORT_FILE"
    send_slack_alert "S3 Alert: Bucket $b has no Public Access Block configuration"
  else
    echo "  PublicAccessBlock: configured" >> "$REPORT_FILE"
  fi

  # Versioning
  v=$(aws s3api get-bucket-versioning --bucket "$b" --output json 2>/dev/null || echo '{}')
  state=$(echo "$v" | jq -r '.Status // "Disabled"')
  echo "  Versioning: $state" >> "$REPORT_FILE"
  if [ "$state" != "Enabled" ]; then
    send_slack_alert "S3 Notice: Bucket $b versioning is not enabled"
  fi

  # Logging
  logcfg=$(aws s3api get-bucket-logging --bucket "$b" --output json 2>/dev/null || echo '{}')
  if echo "$logcfg" | jq -e '.LoggingEnabled? // false' >/dev/null 2>&1; then
    echo "  Logging: enabled" >> "$REPORT_FILE"
  else
    echo "  Logging: disabled" >> "$REPORT_FILE"
  fi

  # Bucket policy public statements (best-effort)
  if aws s3api get-bucket-policy --bucket "$b" --output json >/dev/null 2>&1; then
    pol=$(aws s3api get-bucket-policy --bucket "$b" --output json 2>/dev/null || echo '{}')
    if echo "$pol" | jq -e '.Policy? // empty' >/dev/null 2>&1; then
      if echo "$pol" | jq -r '.Policy' | jq -e 'fromjson | .Statement[]? | select(.Principal=="*" or .Effect=="Allow" and (.Principal|tostring|contains("*")))' >/dev/null 2>&1; then
        echo "  Policy: contains public Allow statements" >> "$REPORT_FILE"
        send_slack_alert "S3 Alert: Bucket $b policy contains public Allow statements"
      else
        echo "  Policy: no obvious public Allow statements" >> "$REPORT_FILE"
      fi
    fi
  else
    echo "  Policy: none" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws s3api list-buckets --query 'Buckets[].Name' --output json 2>/dev/null | jq -r '.[]?' | while read -r bucket; do
    check_bucket "$bucket"
  done

  log_message "S3 encryption audit written to $REPORT_FILE"
}

main "$@"

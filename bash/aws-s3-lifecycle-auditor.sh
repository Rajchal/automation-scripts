#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-s3-lifecycle-auditor.log"
REPORT_FILE="/tmp/s3-lifecycle-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
EXPIRY_THRESHOLD_DAYS="${S3_LIFECYCLE_EXPIRY_THRESHOLD_DAYS:-365}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS S3 Lifecycle Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Expiry threshold days: $EXPIRY_THRESHOLD_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_bucket_lifecycle() {
  local b="$1"
  echo "Bucket: $b" >> "$REPORT_FILE"

  # try to get lifecycle configuration
  if ! out=$(aws s3api get-bucket-lifecycle-configuration --bucket "$b" --output json 2>/dev/null); then
    echo "  NO_LIFECYCLE_CONFIGURATION" >> "$REPORT_FILE"
    send_slack_alert "S3 Alert: Bucket $b has no lifecycle configuration"
    echo "" >> "$REPORT_FILE"
    return
  fi

  echo "$out" | jq -c '.Rules[]? // empty' | while read -r r; do
    id=$(echo "$r" | jq -r '.ID // "<no-id>"')
    status=$(echo "$r" | jq -r '.Status // "Disabled"')
    prefix=$(echo "$r" | jq -r '.Filter | if .Prefix then .Prefix elif .LifecycleRules then .LifecycleRules else "" end // empty' 2>/dev/null || echo "")
    # check expiration
    exp_days=$(echo "$r" | jq -r '.Expiration.Days // empty')
    exp_date=$(echo "$r" | jq -r '.Expiration.Date // empty')
    noncurrent_days=$(echo "$r" | jq -r '.NoncurrentVersionExpiration.NoncurrentDays // empty')
    abort_incomplete=$(echo "$r" | jq -r '.AbortIncompleteMultipartUpload.DaysAfterInitiation // empty')

    echo "  Rule: id=$id status=$status prefix=${prefix:-<all>}" >> "$REPORT_FILE"
    if [ -n "$exp_days" ]; then
      echo "    Expiration: Days=$exp_days" >> "$REPORT_FILE"
      if [ "$exp_days" -gt "$EXPIRY_THRESHOLD_DAYS" ]; then
        echo "    EXPIRY_TOO_LONG: ${exp_days}d" >> "$REPORT_FILE"
        send_slack_alert "S3 Notice: Bucket $b lifecycle rule $id expires after ${exp_days} days (> ${EXPIRY_THRESHOLD_DAYS})"
      fi
    elif [ -n "$exp_date" ]; then
      echo "    ExpirationDate: $exp_date" >> "$REPORT_FILE"
    else
      echo "    NO_EXPIRATION_SET" >> "$REPORT_FILE"
      send_slack_alert "S3 Alert: Bucket $b lifecycle rule $id has no expiration configured"
    fi

    if [ -n "$noncurrent_days" ]; then
      echo "    NoncurrentVersionExpirationDays: $noncurrent_days" >> "$REPORT_FILE"
    fi

    if [ -n "$abort_incomplete" ]; then
      echo "    AbortIncompleteMultipartUploadDays: $abort_incomplete" >> "$REPORT_FILE"
    fi

    # transitions
    echo "$r" | jq -c '.Transitions[]? // empty' | while read -r t; do
      tr_days=$(echo "$t" | jq -r '.Days // empty')
      tr_storage=$(echo "$t" | jq -r '.StorageClass // empty')
      echo "    Transition: to=$tr_storage after=${tr_days}d" >> "$REPORT_FILE"
    done
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws s3api list-buckets --query 'Buckets[].Name' --output json 2>/dev/null | jq -r '.[]?' | while read -r bucket; do
    check_bucket_lifecycle "$bucket"
  done

  log_message "S3 lifecycle audit written to $REPORT_FILE"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudtrail-trail-auditor.log"
REPORT_FILE="/tmp/cloudtrail-trail-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS CloudTrail Trail Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_trail() {
  local name="$1"
  local home_region="$2"
  local is_multi="$3"
  local s3_bucket="$4"
  local log_group_arn="$5"
  local is_logging="$6"

  echo "Trail: $name (homeRegion=$home_region multiRegion=$is_multi)" >> "$REPORT_FILE"

  if [ "$is_logging" != "true" ]; then
    echo "  NOT_LOGGING" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name is not logging"
  fi

  if [ -z "$s3_bucket" ] || [ "$s3_bucket" = "null" ]; then
    echo "  NO_S3_DESTINATION" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name has no S3 bucket destination"
  else
    echo "  S3 bucket: $s3_bucket" >> "$REPORT_FILE"
    # check S3 bucket logging/ACLs is best-effort (requires permissions)
    # we will note existence
  fi

  if [ -z "$log_group_arn" ] || [ "$log_group_arn" = "null" ]; then
    echo "  NO_CLOUDWATCH_LOGS" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name has no CloudWatch Logs destination"
  else
    echo "  CloudWatch Logs: $log_group_arn" >> "$REPORT_FILE"
  fi

  if [ "$is_multi" = "true" ]; then
    echo "  Multi-region: enabled" >> "$REPORT_FILE"
  else
    echo "  Multi-region: disabled" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Notice: Trail $name is not multi-region"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  trails_json=$(aws cloudtrail describe-trails --output json 2>/dev/null || echo '{"trailList":[]}')
  echo "$trails_json" | jq -c '.trailList[]? // empty' | while read -r t; do
    name=$(echo "$t" | jq -r '.Name // ""')
    homeRegion=$(echo "$t" | jq -r '.HomeRegion // ""')
    isMultiRegion=$(echo "$t" | jq -r '.IsMultiRegionTrail // false')
    s3Bucket=$(echo "$t" | jq -r '.S3BucketName // empty')
    logGroupArn=$(echo "$t" | jq -r '.CloudWatchLogsLogGroupArn // empty')

    status_json=$(aws cloudtrail get-trail-status --name "$name" --output json 2>/dev/null || echo '{}')
    isLogging=$(echo "$status_json" | jq -r '.IsLogging // false')

    check_trail "$name" "$homeRegion" "$isMultiRegion" "$s3Bucket" "$logGroupArn" "$isLogging"
  done

  # If no trails found, report
  if [ -z "$(echo "$trails_json" | jq -r '.trailList | length')" ] || [ "$(echo "$trails_json" | jq -r '.trailList | length')" = "0" ]; then
    echo "No CloudTrail trails found." >> "$REPORT_FILE"
    log_message "No CloudTrail trails found"
  fi

  log_message "CloudTrail audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudtrail-trail-auditor.log"
REPORT_FILE="/tmp/cloudtrail-trail-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS CloudTrail Trail Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_trail() {
  local name="$1"
  echo "Trail: $name" >> "$REPORT_FILE"

  trail=$(aws cloudtrail get-trail --name "$name" --output json 2>/dev/null || echo '{}')
  status=$(aws cloudtrail get-trail-status --name "$name" --output json 2>/dev/null || echo '{}')

  s3bucket=$(echo "$trail" | jq -r '.Trail.S3BucketName // empty')
  is_multi=$(echo "$trail" | jq -r '.Trail.IsMultiRegionTrail // false')
  log_file_validation=$(echo "$trail" | jq -r '.Trail.LogFileValidationEnabled // false')
  cwlog_arn=$(echo "$trail" | jq -r '.Trail.CloudWatchLogsLogGroupArn // empty')
  is_logging=$(echo "$status" | jq -r '.IsLogging // false')

  echo "  S3Bucket: ${s3bucket:-<none>}" >> "$REPORT_FILE"
  echo "  MultiRegion: $is_multi" >> "$REPORT_FILE"
  echo "  LogFileValidation: $log_file_validation" >> "$REPORT_FILE"
  echo "  CloudWatchLogsLogGroupArn: ${cwlog_arn:-<none>}" >> "$REPORT_FILE"
  echo "  IsLogging: $is_logging" >> "$REPORT_FILE"

  if [ -z "$s3bucket" ]; then
    echo "  ALERT: No S3 bucket configured for trail $name" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name has no S3 bucket configured"
  else
    # check bucket encryption and ACLs (best-effort)
    enc=$(aws s3api get-bucket-encryption --bucket "$s3bucket" --output json 2>/dev/null || echo '{}')
    if echo "$enc" | jq -e '.Rules? // empty' >/dev/null 2>&1; then
      echo "  S3 encryption: enabled" >> "$REPORT_FILE"
    else
      echo "  ALERT: S3 bucket $s3bucket for trail $name has no default encryption" >> "$REPORT_FILE"
      send_slack_alert "CloudTrail Alert: Bucket $s3bucket used by trail $name has no default encryption"
    fi
  fi

  if [ "$is_multi" != "true" ]; then
    echo "  ALERT: Trail $name is not multi-region" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name is not configured as multi-region"
  fi

  if [ "$log_file_validation" != "true" ]; then
    echo "  ALERT: Log file validation is not enabled for trail $name" >> "$REPORT_FILE"
    send_slack_alert "CloudTrail Alert: Trail $name does not have log file validation enabled"
  fi

  if [ -z "$cwlog_arn" ]; then
    echo "  NOTICE: No CloudWatch Logs group configured for trail $name" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  trails_json=$(aws cloudtrail describe-trails --output json 2>/dev/null || echo '{"trailList":[]}')
  echo "$trails_json" | jq -c '.trailList[]? // empty' | while read -r t; do
    tname=$(echo "$t" | jq -r '.Name // .TrailARN // empty')
    if [ -n "$tname" ]; then
      check_trail "$tname"
    fi
  done

  log_message "CloudTrail audit written to $REPORT_FILE"
}

main "$@"

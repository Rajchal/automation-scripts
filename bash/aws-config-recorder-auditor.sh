#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-config-recorder-auditor.log"
REPORT_FILE="/tmp/config-recorder-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS Config Recorder & Delivery Channel Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_recorders() {
  recs=$(aws configservice describe-configuration-recorders --output json 2>/dev/null || echo '{"ConfigurationRecorders":[]}')
  rec_count=$(echo "$recs" | jq -r '.ConfigurationRecorders | length')
  if [ "$rec_count" -eq 0 ]; then
    echo "NO_CONFIGURATION_RECORDER" >> "$REPORT_FILE"
    send_slack_alert "AWS Config Alert: No configuration recorders found"
    return
  fi

  echo "$recs" | jq -c '.ConfigurationRecorders[]? // empty' | while read -r r; do
    name=$(echo "$r" | jq -r '.name // ""')
    role=$(echo "$r" | jq -r '.roleARN // empty')
    recording_groups=$(echo "$r" | jq -c '.recordingGroup // empty')
    echo "ConfigurationRecorder: $name role=$role" >> "$REPORT_FILE"
    echo "  RecordingGroup: $(echo "$recording_groups" | jq -r 'to_entries|map("\(.key)=\(.value)")|join(",")')" >> "$REPORT_FILE"
  done

  # recorder status
  statuses=$(aws configservice describe-configuration-recorder-status --output json 2>/dev/null || echo '{"ConfigurationRecordersStatus":[]}')
  echo "$statuses" | jq -c '.ConfigurationRecordersStatus[]? // empty' | while read -r s; do
    n=$(echo "$s" | jq -r '.name')
    rec_status=$(echo "$s" | jq -r '.recording // false')
    last_start=$(echo "$s" | jq -r '.lastStartTime // empty')
    last_stop=$(echo "$s" | jq -r '.lastStopTime // empty')
    echo "Status for recorder $n: recording=$rec_status lastStart=$last_start lastStop=$last_stop" >> "$REPORT_FILE"
    if [ "$rec_status" != "true" ]; then
      send_slack_alert "AWS Config Alert: Configuration recorder $n is not recording"
    fi
  done
}

check_delivery_channels() {
  dcs=$(aws configservice describe-delivery-channels --output json 2>/dev/null || echo '{"DeliveryChannels":[]}')
  dc_count=$(echo "$dcs" | jq -r '.DeliveryChannels | length')
  if [ "$dc_count" -eq 0 ]; then
    echo "NO_DELIVERY_CHANNELS" >> "$REPORT_FILE"
    send_slack_alert "AWS Config Alert: No delivery channels configured"
    return
  fi

  echo "$dcs" | jq -c '.DeliveryChannels[]? // empty' | while read -r dc; do
    name=$(echo "$dc" | jq -r '.name // ""')
    s3bucket=$(echo "$dc" | jq -r '.s3BucketName // empty')
    s3prefix=$(echo "$dc" | jq -r '.s3KeyPrefix // empty')
    sns=$(echo "$dc" | jq -r '.snsTopicARN // empty')
    echo "DeliveryChannel: $name s3=$s3bucket prefix=$s3prefix sns=$sns" >> "$REPORT_FILE"

    if [ -z "$s3bucket" ] || [ "$s3bucket" = "null" ]; then
      echo "  NO_S3_BUCKET_CONFIGURED" >> "$REPORT_FILE"
      send_slack_alert "AWS Config Alert: Delivery channel $name has no S3 bucket configured"
    else
      # check bucket exists (best-effort)
      if ! aws s3api head-bucket --bucket "$s3bucket" >/dev/null 2>&1; then
        echo "  S3_BUCKET_NOT_ACCESSIBLE: $s3bucket" >> "$REPORT_FILE"
        send_slack_alert "AWS Config Alert: Delivery channel $name references inaccessible S3 bucket $s3bucket"
      fi
    fi

    if [ -z "$sns" ] || [ "$sns" = "null" ]; then
      echo "  NO_SNS_TOPIC_CONFIGURED" >> "$REPORT_FILE"
      # SNS optional, just note
    fi
  done
}

main() {
  write_header
  check_recorders
  echo "" >> "$REPORT_FILE"
  check_delivery_channels
  log_message "Config recorder audit written to $REPORT_FILE"
}

main "$@"

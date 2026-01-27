#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ec2-unused-volumes-auditor.log"
REPORT_FILE="/tmp/ec2-unused-volumes-auditor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
DAYS_OLD="${EBS_UNUSED_DAYS:-30}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

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
  echo "EBS Unused Volumes Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Unused threshold (days): $DAYS_OLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  cutoff_epoch=$(date -d "-$DAYS_OLD days" +%s)

  vols_json=$(aws ec2 describe-volumes --filters Name=status,Values=available --region "$REGION" --output json 2>/dev/null || echo '{"Volumes":[]}')
  vols_count=$(echo "$vols_json" | jq '.Volumes | length')

  if [ "$vols_count" -eq 0 ]; then
    echo "No unattached EBS volumes found." >> "$REPORT_FILE"
    log_message "No unattached EBS volumes in region $REGION"
    exit 0
  fi

  stale_found=0
  echo "Found $vols_count unattached volumes" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  echo "$vols_json" | jq -c '.Volumes[]' | while read -r v; do
    vol_id=$(echo "$v" | jq -r '.VolumeId')
    create_time=$(echo "$v" | jq -r '.CreateTime')
    create_epoch=$(date -d "$create_time" +%s 2>/dev/null || echo 0)
    age_days=$(( ( $(date +%s) - create_epoch ) / 86400 ))
    size_gb=$(echo "$v" | jq -r '.Size')
    az=$(echo "$v" | jq -r '.AvailabilityZone')

    echo "Volume: $vol_id" >> "$REPORT_FILE"
    echo "Created: $create_time ($age_days days)" >> "$REPORT_FILE"
    echo "Size(GB): $size_gb" >> "$REPORT_FILE"
    echo "AZ: $az" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$age_days" -ge "$DAYS_OLD" ]; then
      echo "ALERT: Volume $vol_id is unattached and $age_days days old." >> "$REPORT_FILE"
      send_slack_alert "EBS Alert: Volume $vol_id is unattached in $REGION (age=${age_days}d, size=${size_gb}GB, az=$az). Consider snapshot+delete." 
      stale_found=1
    fi
  done

  if [ "$stale_found" -eq 0 ]; then
    echo "No stale unattached volumes older than $DAYS_OLD days." >> "$REPORT_FILE"
  fi

  log_message "EBS auditor report written to $REPORT_FILE"
}

main "$@"

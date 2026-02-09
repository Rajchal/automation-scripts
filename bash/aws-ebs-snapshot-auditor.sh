#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ebs-snapshot-auditor.log"
REPORT_FILE="/tmp/ebs-snapshot-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
OLD_DAYS="${EBS_SNAPSHOT_OLD_DAYS:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS EBS Snapshot Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Old threshold (days): $OLD_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_snapshots() {
  # list snapshots owned by self
  aws ec2 describe-snapshots --owner-ids self --query 'Snapshots[]' --output json 2>/dev/null | jq -c '.[]? // empty' | while read -r s; do
    sid=$(echo "$s" | jq -r '.SnapshotId')
    vol=$(echo "$s" | jq -r '.VolumeId // ""')
    start_time=$(echo "$s" | jq -r '.StartTime')
    tags=$(echo "$s" | jq -c '.Tags // []')

    # calculate age
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null || true)
    if [ -n "$start_epoch" ]; then
      age_days=$(( ( $(date +%s) - start_epoch ) / 86400 ))
    else
      age_days=0
    fi

    # skip snapshots explicitly tagged to retain
    retain=$(echo "$tags" | jq -r '.[]? | select(.Key=="retain" or .Key=="Retain") | .Value' || true)
    if [ -n "$retain" ]; then
      echo "Snapshot $sid (vol=$vol) age=${age_days}d - retained by tag" >> "$REPORT_FILE"
      continue
    fi

    if [ "$age_days" -ge "$OLD_DAYS" ]; then
      echo "OLD_SNAPSHOT: $sid volume=$vol age=${age_days}d" >> "$REPORT_FILE"
      send_slack_alert "EBS Snapshot Alert: Snapshot $sid (vol=$vol) is ${age_days} days old"
    fi

    # check for orphaned volumes: if volume is empty or deleted, note snapshot status
    if [ -z "$vol" ] || [ "$vol" = "null" ]; then
      echo "  ORPHANED_SNAPSHOT: $sid (no volume)" >> "$REPORT_FILE"
      send_slack_alert "EBS Snapshot Alert: Snapshot $sid has no associated volume"
    else
      # verify volume exists
      if ! aws ec2 describe-volumes --volume-ids "$vol" --output json >/dev/null 2>&1; then
        echo "  ORPHANED_SNAPSHOT: $sid volume=$vol (volume not found)" >> "$REPORT_FILE"
        send_slack_alert "EBS Snapshot Alert: Snapshot $sid references missing volume $vol"
      fi
    fi

    echo "" >> "$REPORT_FILE"
  done
}

main() {
  write_header
  check_snapshots
  log_message "EBS snapshot audit written to $REPORT_FILE"
}

main "$@"
#!/bin/bash

################################################################################
# AWS EBS Snapshot Auditor
# Audits EBS snapshots for age, public/shared access, encryption, and orphaned snapshots
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ebs-snapshot-audit-$(date +%s).txt"
LOG_FILE="/var/log/ebs-snapshot-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
SNAPSHOT_AGE_WARN_DAYS="${SNAPSHOT_AGE_WARN_DAYS:-90}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_snapshots() {
  aws ec2 describe-snapshots --owner-ids self --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_snapshot_attribute() {
  local snapshot_id="$1"
  aws ec2 describe-snapshot-attribute --snapshot-id "${snapshot_id}" --attribute createVolumePermission --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_images_by_snapshot() {
  local snapshot_id="$1"
  aws ec2 describe-images --region "${REGION}" --filters Name=block-device-mapping.snapshot-id,Values="${snapshot_id}" --owners self --output json 2>/dev/null || echo '{}'
}

describe_volumes() {
  local volume_id="$1"
  aws ec2 describe-volumes --region "${REGION}" --volume-ids "${volume_id}" --output json 2>/dev/null || echo '{}'
}

list_tags() {
  local snapshot_id="$1"
  aws ec2 describe-tags --region "${REGION}" --filters Name=resource-id,Values="${snapshot_id}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS EBS Snapshot Audit Report"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Snapshot Age Warn: ${SNAPSHOT_AGE_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_snapshots() {
  log_message INFO "Auditing EBS snapshots"
  {
    echo "=== EBS SNAPSHOTS ==="
  } >> "${OUTPUT_FILE}"

  local snapshots_json
  snapshots_json=$(list_snapshots)

  local total=0 old_count=0 expired_count=0 public_count=0 shared_count=0 unencrypted=0 encrypted=0 orphaned=0

  echo "${snapshots_json}" | jq -c '.Snapshots[]?' 2>/dev/null | while read -r snap; do
    ((total++))
    local snap_id start_time desc encrypted_flag owner_id volume_id
    snap_id=$(echo "${snap}" | jq_safe '.SnapshotId')
    start_time=$(echo "${snap}" | jq_safe '.StartTime')
    desc=$(echo "${snap}" | jq_safe '.Description')
    encrypted_flag=$(echo "${snap}" | jq_safe '.Encrypted')
    owner_id=$(echo "${snap}" | jq_safe '.OwnerId')
    volume_id=$(echo "${snap}" | jq_safe '.VolumeId')

    # Compute age in days
    local age_days=0
    if [[ -n "${start_time}" && "${start_time}" != "null" ]]; then
      local start_epoch now_epoch
      start_epoch=$(date -d "${start_time}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      age_days=$(( (now_epoch - start_epoch) / 86400 ))
    fi

    {
      echo "Snapshot: ${snap_id}"
      echo "  StartTime: ${start_time}"
      echo "  AgeDays: ${age_days}"
      echo "  Description: ${desc}"
      echo "  VolumeId: ${volume_id}"
      echo "  Encrypted: ${encrypted_flag}"
    } >> "${OUTPUT_FILE}"

    if [[ "${encrypted_flag}" != "true" ]]; then
      ((unencrypted++))
      echo "  WARNING: Snapshot is not encrypted" >> "${OUTPUT_FILE}"
    else
      ((encrypted++))
    fi

    if (( age_days >= SNAPSHOT_AGE_WARN_DAYS )); then
      ((old_count++))
      echo "  WARNING: Snapshot older than ${SNAPSHOT_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
    fi

    # Check public/shared
    local attr
    attr=$(describe_snapshot_attribute "${snap_id}")
    if echo "${attr}" | jq -e '.CreateVolumePermissions[]? | select(.Group=="all")' >/dev/null 2>&1; then
      ((public_count++))
      echo "  WARNING: Snapshot is public (createVolumePermission=all)" >> "${OUTPUT_FILE}"
    fi
    if echo "${attr}" | jq -e '.CreateVolumePermissions[]? | select(.UserId) ' >/dev/null 2>&1; then
      # count unique shared account ids
      local shared_accounts
      shared_accounts=$(echo "${attr}" | jq -r '.CreateVolumePermissions[]?.UserId' 2>/dev/null | sort -u | wc -l)
      if (( shared_accounts > 0 )); then
        ((shared_count++))
        echo "  INFO: Snapshot shared with ${shared_accounts} account(s)" >> "${OUTPUT_FILE}"
      fi
    fi

    # Check if snapshot used by any AMI owned by us
    local images
    images=$(describe_images_by_snapshot "${snap_id}")
    local ami_count
    ami_count=$(echo "${images}" | jq '.Images | length' 2>/dev/null || echo 0)
    if (( ami_count == 0 )); then
      # If volume id exists, check if volume still exists
      if [[ -n "${volume_id}" && "${volume_id}" != "null" ]]; then
        local vol
        vol=$(describe_volumes "${volume_id}")
        local vol_len
        vol_len=$(echo "${vol}" | jq '.Volumes | length' 2>/dev/null || echo 0)
        if (( vol_len == 0 )); then
          ((orphaned++))
          echo "  INFO: Snapshot created from deleted volume (possibly orphaned)" >> "${OUTPUT_FILE}"
        fi
      else
        # No volume id and no AMI references -> potentially orphan
        ((orphaned++))
        echo "  INFO: Snapshot not referenced by any AMI (potentially orphan)" >> "${OUTPUT_FILE}"
      fi
    else
      echo "  Used By AMIs: ${ami_count}" >> "${OUTPUT_FILE}"
    fi

    # Tags
    local tags
    tags=$(list_tags "${snap_id}")
    if echo "${tags}" | jq -e '.Tags | length > 0' >/dev/null 2>&1; then
      echo "  Tags: $(echo "${tags}" | jq -c '.Tags')" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Snapshot Summary:"
    echo "  Total Snapshots: ${total}"
    echo "  Encrypted: ${encrypted}"
    echo "  Unencrypted: ${unencrypted}"
    echo "  Old (>= ${SNAPSHOT_AGE_WARN_DAYS}d): ${old_count}"
    echo "  Public Snapshots: ${public_count}"
    echo "  Shared Snapshots: ${shared_count}"
    echo "  Potentially Orphaned: ${orphaned}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local old="$2"; local public="$3"; local orphaned="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( public > 0 || orphaned > 0 )) && color="danger"
  (( old > 0 && public == 0 && orphaned == 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS EBS Snapshot Audit Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Snapshots", "value": "${total}", "short": true},
        {"title": "Old (>= ${SNAPSHOT_AGE_WARN_DAYS}d)", "value": "${old}", "short": true},
        {"title": "Public", "value": "${public}", "short": true},
        {"title": "Potentially Orphaned", "value": "${orphaned}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting EBS snapshot audit"
  write_header
  audit_snapshots
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total old public orphaned
  total=$(grep "Total Snapshots:" "${OUTPUT_FILE}" | awk '{print $NF}')
  old=$(grep "Old (>= " -n "${OUTPUT_FILE}" | awk -F: '{print $2}' | awk '{print $NF}' 2>/dev/null || true)
  if [[ -z "${old}" ]]; then old=0; fi
  public=$(grep "Public Snapshots:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  orphaned=$(grep "Potentially Orphaned:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${total}" "${old}" "${public}" "${orphaned}"
  cat "${OUTPUT_FILE}"
}

main "$@"

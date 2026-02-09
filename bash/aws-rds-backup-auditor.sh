#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-rds-backup-auditor.log"
REPORT_FILE="/tmp/rds-backup-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MIN_RETENTION_DAYS="${RDS_MIN_RETENTION_DAYS:-7}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS RDS Backup & Retention Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Minimum retention days: $MIN_RETENTION_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_instance() {
  local dbid="$1"
  echo "DBInstance: $dbid" >> "$REPORT_FILE"

  inst=$(aws rds describe-db-instances --db-instance-identifier "$dbid" --output json 2>/dev/null || echo '{}')
  backup_retention=$(echo "$inst" | jq -r '.DBInstances[0].BackupRetentionPeriod // empty')
  encrypted=$(echo "$inst" | jq -r '.DBInstances[0].StorageEncrypted // false')
  public=$(echo "$inst" | jq -r '.DBInstances[0].PubliclyAccessible // false')
  engine=$(echo "$inst" | jq -r '.DBInstances[0].Engine // ""')

  if [ -z "$backup_retention" ]; then
    echo "  BACKUP_RETENTION: unknown" >> "$REPORT_FILE"
  else
    echo "  BackupRetentionDays: $backup_retention" >> "$REPORT_FILE"
    if [ "$backup_retention" -lt "$MIN_RETENTION_DAYS" ]; then
      echo "  RETENTION_TOO_LOW" >> "$REPORT_FILE"
      send_slack_alert "RDS Alert: $dbid has BackupRetentionDays=$backup_retention (< $MIN_RETENTION_DAYS)"
    fi
  fi

  if [ "$encrypted" != "true" ]; then
    echo "  NOT_ENCRYPTED" >> "$REPORT_FILE"
    send_slack_alert "RDS Alert: $dbid storage is not encrypted"
  else
    echo "  Encrypted: yes" >> "$REPORT_FILE"
  fi

  if [ "$public" = "true" ]; then
    echo "  PUBLICLY_ACCESSIBLE" >> "$REPORT_FILE"
    send_slack_alert "RDS Alert: $dbid is publicly accessible"
  fi

  # check latest automated snapshot age
  snaps=$(aws rds describe-db-snapshots --db-instance-identifier "$dbid" --snapshot-type automated --output json 2>/dev/null || echo '{"DBSnapshots":[]}')
  latest=$(echo "$snaps" | jq -c '.DBSnapshots | sort_by(.SnapshotCreateTime) | last? // empty')
  if [ -n "$latest" ]; then
    time=$(echo "$latest" | jq -r '.SnapshotCreateTime')
    epoch=$(date -d "$time" +%s 2>/dev/null || true)
    if [ -n "$epoch" ]; then
      age_days=$(( ( $(date +%s) - epoch ) / 86400 ))
      echo "  Latest automated snapshot: $time (age ${age_days}d)" >> "$REPORT_FILE"
      if [ "$age_days" -gt 7 ]; then
        send_slack_alert "RDS Alert: $dbid latest automated snapshot is ${age_days} days old"
      fi
    fi
  else
    echo "  NO_AUTOMATED_SNAPSHOTS" >> "$REPORT_FILE"
    send_slack_alert "RDS Alert: $dbid has no automated snapshots"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws rds describe-db-instances --output json 2>/dev/null | jq -c '.DBInstances[]? // empty' | while read -r d; do
    id=$(echo "$d" | jq -r '.DBInstanceIdentifier')
    check_instance "$id"
  done

  log_message "RDS backup audit written to $REPORT_FILE"
}

main "$@"

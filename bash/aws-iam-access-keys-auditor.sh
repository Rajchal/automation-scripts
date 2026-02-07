#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-iam-access-keys-auditor.log"
REPORT_FILE="/tmp/iam-access-keys-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ROTATION_MAX_AGE_DAYS="${IAM_KEY_MAX_AGE_DAYS:-90}"
INACTIVE_DAYS_THRESHOLD="${IAM_KEY_INACTIVE_DAYS:-90}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS IAM Access Keys Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Rotation max age (days): $ROTATION_MAX_AGE_DAYS" >> "$REPORT_FILE"
  echo "Inactive threshold (days): $INACTIVE_DAYS_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_access_key() {
  local user="$1"
  local access_key_id="$2"
  local create_date="$3"
  local status="$4"

  echo "User: $user Key: $access_key_id Status: $status CreateDate: $create_date" >> "$REPORT_FILE"

  last_used_json=$(aws iam get-access-key-last-used --access-key-id "$access_key_id" --output json 2>/dev/null || echo '{}')
  last_used_date=$(echo "$last_used_json" | jq -r '.AccessKeyLastUsed.LastUsedDate // empty')

  if [ -n "$last_used_date" ]; then
    last_epoch=$(date -d "$last_used_date" +%s 2>/dev/null || true)
    now=$(date +%s)
    if [ -n "$last_epoch" ]; then
      idle_days=$(( (now - last_epoch) / 86400 ))
      echo "  LastUsed: $last_used_date (idle ${idle_days}d)" >> "$REPORT_FILE"
      if [ "$idle_days" -ge "$INACTIVE_DAYS_THRESHOLD" ]; then
        echo "  INACTIVE_KEY: idle ${idle_days}d >= ${INACTIVE_DAYS_THRESHOLD}d" >> "$REPORT_FILE"
        send_slack_alert "IAM Alert: Access key $access_key_id for user $user unused for ${idle_days} days"
      fi
    fi
  else
    echo "  LastUsed: NEVER" >> "$REPORT_FILE"
    # if created long ago, flag
    if [ -n "$create_date" ]; then
      create_epoch=$(date -d "$create_date" +%s 2>/dev/null || true)
      if [ -n "$create_epoch" ]; then
        age_days=$(( ( $(date +%s) - create_epoch ) / 86400 ))
        echo "  Age: ${age_days}d" >> "$REPORT_FILE"
        if [ "$age_days" -ge "$ROTATION_MAX_AGE_DAYS" ]; then
          echo "  ROTATION_AGE_EXCEEDED: ${age_days}d >= ${ROTATION_MAX_AGE_DAYS}d" >> "$REPORT_FILE"
          send_slack_alert "IAM Alert: Access key $access_key_id for user $user created ${age_days} days ago (>= ${ROTATION_MAX_AGE_DAYS}) and never used"
        fi
      fi
    fi
  fi

  if [ "$status" = "Inactive" ]; then
    echo "  KEY_INACTIVE" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws iam list-users --output json 2>/dev/null | jq -c '.Users[]? // empty' | while read -r u; do
    uname=$(echo "$u" | jq -r '.UserName')
    aws iam list-access-keys --user-name "$uname" --output json 2>/dev/null | jq -c '.AccessKeyMetadata[]? // empty' | while read -r k; do
      akid=$(echo "$k" | jq -r '.AccessKeyId')
      status=$(echo "$k" | jq -r '.Status')
      create_date=$(echo "$k" | jq -r '.CreateDate // empty')
      check_access_key "$uname" "$akid" "$create_date" "$status"
    done
  done

  # Optional: check account root access keys (best-effort)
  root_keys=$(aws iam list-access-keys --user-name root --output json 2>/dev/null || echo '{}')
  if echo "$root_keys" | jq -e '.AccessKeyMetadata? // empty' >/dev/null 2>&1; then
    echo "Root account access keys:" >> "$REPORT_FILE"
    echo "$root_keys" | jq -c '.AccessKeyMetadata[]? // empty' | while read -r rk; do
      akid=$(echo "$rk" | jq -r '.AccessKeyId')
      status=$(echo "$rk" | jq -r '.Status')
      create_date=$(echo "$rk" | jq -r '.CreateDate // empty')
      check_access_key "root" "$akid" "$create_date" "$status"
    done
  fi

  log_message "IAM access-keys audit written to $REPORT_FILE"
}

main "$@"

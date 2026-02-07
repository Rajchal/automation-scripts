#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-iam-access-keys-rotation-auditor.log"
REPORT_FILE="/tmp/iam-access-keys-rotation-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_KEY_AGE_DAYS="${IAM_KEY_MAX_AGE_DAYS:-90}"
INACTIVE_DAYS_WARN="${IAM_KEY_INACTIVE_DAYS_WARN:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "IAM Access Keys Rotation Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Max key age (days): $MAX_KEY_AGE_DAYS" >> "$REPORT_FILE"
  echo "Inactive warn threshold (days): $INACTIVE_DAYS_WARN" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_user_keys() {
  local user="$1"
  echo "User: $user" >> "$REPORT_FILE"

  aws iam list-access-keys --user-name "$user" --output json 2>/dev/null | jq -c '.AccessKeyMetadata[]? // empty' | while read -r k; do
    kid=$(echo "$k" | jq -r '.AccessKeyId')
    status=$(echo "$k" | jq -r '.Status')
    created=$(echo "$k" | jq -r '.CreateDate')

    echo "  Key: $kid status=$status created=$created" >> "$REPORT_FILE"

    # check last used
    last_used_json=$(aws iam get-access-key-last-used --access-key-id "$kid" --output json 2>/dev/null || echo '{}')
    last_used_date=$(echo "$last_used_json" | jq -r '.AccessKeyLastUsed.LastUsedDate // empty')
    last_used_service=$(echo "$last_used_json" | jq -r '.AccessKeyLastUsed.ServiceName // empty')

    if [ -n "$last_used_date" ]; then
      echo "    LastUsed: $last_used_date service=$last_used_service" >> "$REPORT_FILE"
      # compute inactivity
      last_epoch=$(date -d "$last_used_date" +%s 2>/dev/null || true)
      if [ -n "$last_epoch" ]; then
        now=$(date +%s)
        days_inactive=$(( (now - last_epoch) / 86400 ))
        if [ "$days_inactive" -ge "$INACTIVE_DAYS_WARN" ]; then
          echo "    INACTIVE: $days_inactive days since last use" >> "$REPORT_FILE"
          send_slack_alert "IAM Alert: Access key $kid for user $user has not been used for ${days_inactive} days"
        fi
      fi
    else
      echo "    NEVER_USED" >> "$REPORT_FILE"
      send_slack_alert "IAM Alert: Access key $kid for user $user has never been used"
    fi

    # compute age
    if [ -n "$created" ] && [ "$created" != "null" ]; then
      created_epoch=$(date -d "$created" +%s 2>/dev/null || true)
      if [ -n "$created_epoch" ]; then
        age_days=$(( ( $(date +%s) - created_epoch ) / 86400 ))
        if [ "$age_days" -ge "$MAX_KEY_AGE_DAYS" ]; then
          echo "    ROTATION_REQUIRED: age=${age_days}d >= ${MAX_KEY_AGE_DAYS}d" >> "$REPORT_FILE"
          send_slack_alert "IAM Alert: Access key $kid for user $user is ${age_days} days old (>= ${MAX_KEY_AGE_DAYS}), rotate it"
        fi
      fi
    fi

    if [ "$status" != "Active" ]; then
      echo "    STATUS_${status}" >> "$REPORT_FILE"
      send_slack_alert "IAM Alert: Access key $kid for user $user status is $status"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws iam list-users --output json 2>/dev/null | jq -c '.Users[]? // empty' | while read -r u; do
    uname=$(echo "$u" | jq -r '.UserName')
    check_user_keys "$uname"
  done

  log_message "IAM access-keys audit written to $REPORT_FILE"
}

main "$@"

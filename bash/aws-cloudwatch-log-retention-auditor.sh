#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudwatch-log-retention-auditor.log"
REPORT_FILE="/tmp/cloudwatch-log-retention-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DEFAULT_RETENTION_DAYS="${LOG_RETENTION_DEFAULT_DAYS:-90}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS CloudWatch Log Retention Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Default retention threshold (days): $DEFAULT_RETENTION_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_log_group() {
  local name="$1"
  local retention="$2"

  echo "LogGroup: $name" >> "$REPORT_FILE"
  if [ -z "$retention" ] || [ "$retention" = "null" ]; then
    echo "  RETENTION_NOT_CONFIGURED" >> "$REPORT_FILE"
    send_slack_alert "CloudWatch Logs Alert: Log group $name has no retention configured"
  else
    echo "  RetentionDays: $retention" >> "$REPORT_FILE"
    if [ "$retention" -lt "$DEFAULT_RETENTION_DAYS" ]; then
      echo "  RETENTION_TOO_LOW: ${retention}d < ${DEFAULT_RETENTION_DAYS}d" >> "$REPORT_FILE"
      send_slack_alert "CloudWatch Logs Alert: Log group $name retention ${retention} days is below ${DEFAULT_RETENTION_DAYS}d"
    fi
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  next_token=""
  while :; do
    if [ -z "$next_token" ]; then
      out=$(aws logs describe-log-groups --output json 2>/dev/null || echo '{"logGroups":[]}')
    else
      out=$(aws logs describe-log-groups --output json --next-token "$next_token" 2>/dev/null || echo '{"logGroups":[]}')
    fi

    echo "$out" | jq -c '.logGroups[]? // empty' | while read -r g; do
      name=$(echo "$g" | jq -r '.logGroupName')
      retention=$(echo "$g" | jq -r '.retentionInDays // empty')
      check_log_group "$name" "$retention"
    done

    next_token=$(echo "$out" | jq -r '.nextToken // empty')
    if [ -z "$next_token" ]; then
      break
    fi
  done

  log_message "CloudWatch Logs retention audit written to $REPORT_FILE"
}

main "$@"

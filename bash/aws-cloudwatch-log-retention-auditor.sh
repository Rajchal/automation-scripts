#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cloudwatch-log-retention-auditor.log"
REPORT_FILE="/tmp/cloudwatch-log-retention-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MIN_RETENTION_DAYS="${CLOUDWATCH_MIN_RETENTION_DAYS:-14}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS CloudWatch Log Retention Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Min retention days: $MIN_RETENTION_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_log_group() {
  local name="$1"
  local retention="$2"

  echo "LogGroup: $name" >> "$REPORT_FILE"
  if [ -z "$retention" ] || [ "$retention" = "null" ]; then
    echo "  NO_RETENTION_CONFIGURED" >> "$REPORT_FILE"
    send_slack_alert "CloudWatch Alert: Log group $name has no retention configured"
  else
    echo "  RetentionDays: $retention" >> "$REPORT_FILE"
    if [ "$retention" -lt "$MIN_RETENTION_DAYS" ]; then
      echo "  RETENTION_TOO_LOW" >> "$REPORT_FILE"
      send_slack_alert "CloudWatch Alert: Log group $name retention ${retention}d < ${MIN_RETENTION_DAYS}d"
    fi
  fi

  # check subscription filters (best-effort)
  sub_count=$(aws logs describe-subscription-filters --log-group-name "$name" --output json 2>/dev/null | jq -r '.subscriptionFilters | length' || echo 0)
  if [ "$sub_count" -eq 0 ]; then
    echo "  NO_SUBSCRIPTION_FILTERS" >> "$REPORT_FILE"
  else
    echo "  SubscriptionFilters: $sub_count" >> "$REPORT_FILE"
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

    echo "$out" | jq -c '.logGroups[]? // empty' | while read -r lg; do
      name=$(echo "$lg" | jq -r '.logGroupName')
      retention=$(echo "$lg" | jq -r '.retentionInDays // empty')
      check_log_group "$name" "$retention"
    done

    next_token=$(echo "$out" | jq -r '.nextToken // empty')
    if [ -z "$next_token" ]; then
      break
    fi
  done

  log_message "CloudWatch Log retention audit written to $REPORT_FILE"
}

main "$@"
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

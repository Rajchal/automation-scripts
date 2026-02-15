#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-sns-subscription-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

log_message() {
  local msg="$1"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${msg}" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  local text="$1"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    jq -n --arg t "$text" '{text:$t}' | curl -s -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  cat > "$REPORT_FILE" <<EOF
AWS SNS Subscriptions Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

check_subscription() {
  local topic_arn="$1"
  local subs
  subs=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" --output json 2>/dev/null || echo '{}')
  echo "$subs" | jq -c '.Subscriptions[]? // empty' | while read -r s; do
    local protocol endpoint sub_arn
    protocol=$(echo "$s" | jq -r '.Protocol // "<unknown>"')
    endpoint=$(echo "$s" | jq -r '.Endpoint // "<none>"')
    sub_arn=$(echo "$s" | jq -r '.SubscriptionArn // "<pending>"')

    local issues=()
    if [ "$protocol" = "http" ]; then
      issues+=("Subscription uses HTTP (not HTTPS): $endpoint")
    fi
    if [ "$sub_arn" = "PendingConfirmation" ] || [ "$sub_arn" = "<pending>" ]; then
      issues+=("Subscription pending confirmation: endpoint=$endpoint protocol=$protocol")
    fi
    if [[ "$protocol" == "email" || "$protocol" == "email-json" ]] && [[ "$endpoint" != *"@"* ]]; then
      issues+=("Email subscription with non-email endpoint: $endpoint")
    fi

    if [ ${#issues[@]} -gt 0 ]; then
      echo "Topic: $topic_arn" >> "$REPORT_FILE"
      echo "  SubscriptionArn: $sub_arn" >> "$REPORT_FILE"
      echo "  Protocol: $protocol" >> "$REPORT_FILE"
      echo "  Endpoint: $endpoint" >> "$REPORT_FILE"
      for it in "${issues[@]}"; do
        echo "    - $it" >> "$REPORT_FILE"
      done
      echo >> "$REPORT_FILE"
    fi
  done
}

main() {
  write_header
  log_message "Starting SNS subscriptions auditor"

  local topics
  topics=$(aws sns list-topics --output json 2>/dev/null | jq -r '.Topics[]?.TopicArn') || true
  if [ -z "$topics" ]; then
    log_message "No SNS topics found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for t in $topics; do
    check_subscription "$t"
  done

  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "SNS subscription auditor found issues; see $REPORT_FILE on host."
  else
    log_message "No issues found for SNS subscriptions"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"

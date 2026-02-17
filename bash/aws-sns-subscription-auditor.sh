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
  local sub_json="$1"
  local topic_arn
  topic_arn=$(echo "$sub_json" | jq -r '.TopicArn // "<unknown>"')
  local sub_arn
  sub_arn=$(echo "$sub_json" | jq -r '.SubscriptionArn // "<unknown>"')
  local protocol
  protocol=$(echo "$sub_json" | jq -r '.Protocol // "<unknown>"')
  local endpoint
  endpoint=$(echo "$sub_json" | jq -r '.Endpoint // "<unknown>"')
  local raw
  raw=$(echo "$sub_json" | jq -r '.RawMessageDelivery // "false"')

  local findings=()
  if [ "$sub_arn" = "PendingConfirmation" ]; then
    findings+=("Subscription pending confirmation")
  fi
  if [[ "$protocol" =~ ^http$ ]] && [[ "$endpoint" =~ ^http:// ]]; then
    findings+=("Insecure HTTP endpoint for protocol=http: $endpoint")
  fi
  if [ "$protocol" = "email" ] || [ "$protocol" = "email-json" ]; then
    # email confirmation appears as PendingConfirmation in SubscriptionArn
    if [ "$sub_arn" = "<unknown>" ] || [ -z "$sub_arn" ]; then
      findings+=("Email subscription without confirmed ARN: $endpoint")
    fi
  fi
  if [ "$raw" != "true" ]; then
    findings+=("RawMessageDelivery not enabled (messages may be JSON-wrapped)")
  fi

  if [ ${#findings[@]} -gt 0 ]; then
    echo "Topic: $topic_arn" >> "$REPORT_FILE"
    echo "Subscription: $sub_arn" >> "$REPORT_FILE"
    echo "  Protocol: $protocol" >> "$REPORT_FILE"
    echo "  Endpoint: $endpoint" >> "$REPORT_FILE"
    for f in "${findings[@]}"; do
      echo "  - $f" >> "$REPORT_FILE"
    done
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting SNS subscriptions auditor"

  local subs_json
  subs_json=$(aws sns list-subscriptions --output json 2>/dev/null || echo '{"Subscriptions":[]}')
  local subs
  subs=$(echo "$subs_json" | jq -c '.Subscriptions[]?') || subs=""
  if [ -z "$subs" ]; then
    log_message "No subscriptions found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  echo "$subs" | while read -r s; do
    if check_subscription "$s"; then
      any=1
      log_message "Findings for subscription: $(echo "$s" | jq -r '.SubscriptionArn // .Endpoint')"
    fi
  done

  # The while above runs in a subshell; detect report file size instead
  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "SNS subscriptions auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No issues found for SNS subscriptions"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
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

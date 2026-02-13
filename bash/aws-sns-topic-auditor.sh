#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-sns-topic-auditor.log"
REPORT_FILE="/tmp/sns-topic-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS SNS Topic Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_topic() {
  local arn="$1"
  echo "Topic: $arn" >> "$REPORT_FILE"

  # check subscriptions
  subs_json=$(aws sns list-subscriptions-by-topic --topic-arn "$arn" --output json 2>/dev/null || echo '{"Subscriptions":[]}')
  sub_count=$(echo "$subs_json" | jq -r '.Subscriptions | length')
  echo "  Subscriptions: $sub_count" >> "$REPORT_FILE"
  if [ "$sub_count" -eq 0 ]; then
    echo "  NO_SUBSCRIPTIONS" >> "$REPORT_FILE"
    send_slack_alert "SNS Alert: Topic $arn has no subscriptions"
  else
    echo "$subs_json" | jq -c '.Subscriptions[]? // empty' | while read -r s; do
      protocol=$(echo "$s" | jq -r '.Protocol // ""')
      endpoint=$(echo "$s" | jq -r '.Endpoint // ""')
      owner=$(echo "$s" | jq -r '.Owner // ""')
      echo "    Subscription: protocol=$protocol endpoint=$endpoint owner=$owner" >> "$REPORT_FILE"

      # flag insecure endpoints
      if [ "$protocol" = "http" ]; then
        echo "      INSECURE_SUBSCRIPTION_HTTP" >> "$REPORT_FILE"
        send_slack_alert "SNS Alert: Topic $arn has HTTP subscription endpoint $endpoint (use HTTPS)"
      fi
      if [ "$protocol" = "email" ] || [ "$protocol" = "sms" ]; then
        echo "      HUMAN_CHANNEL_SUBSCRIPTION" >> "$REPORT_FILE"
      fi
    done
  fi

  # check topic attributes: policy, kms master key id
  attrs=$(aws sns get-topic-attributes --topic-arn "$arn" --output json 2>/dev/null || echo '{}')
  policy=$(echo "$attrs" | jq -r '.Attributes.Policy // empty')
  kms=$(echo "$attrs" | jq -r '.Attributes.KmsMasterKeyId // empty')
  display=$(echo "$attrs" | jq -r '.Attributes.DisplayName // empty')

  if [ -n "$policy" ] && [ "$policy" != "" ]; then
    if echo "$policy" | jq -e 'fromjson | .Statement[]? | select(.Principal=="*")' >/dev/null 2>&1; then
      echo "  POLICY_WIDE_PRINCIPAL_STAR" >> "$REPORT_FILE"
      send_slack_alert "SNS Alert: Topic $arn policy allows wildcard principal '*'"
    fi
  fi

  if [ -z "$kms" ] || [ "$kms" = "null" ]; then
    echo "  NOT_ENCRYPTED_WITH_KMS" >> "$REPORT_FILE"
    send_slack_alert "SNS Notice: Topic $arn has no KMS encryption configured"
  else
    echo "  KMS Key: $kms" >> "$REPORT_FILE"
  fi

  if [ -n "$display" ]; then
    echo "  DisplayName: $display" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws sns list-topics --output json 2>/dev/null | jq -c '.Topics[]? // empty' | while read -r t; do
    arn=$(echo "$t" | jq -r '.TopicArn')
    check_topic "$arn"
  done

  log_message "SNS topic audit written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-sns-topic-auditor.log"
REPORT_FILE="/tmp/sns-topic-auditor-$(date +%Y%m%d%H%M%S).txt"
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
  echo "AWS SNS Topic Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_topic() {
  local arn="$1"
  echo "Topic: $arn" >> "$REPORT_FILE"

  # get attributes
  attrs=$(aws sns get-topic-attributes --topic-arn "$arn" --output json 2>/dev/null || echo '{}')
  policy=$(echo "$attrs" | jq -r '.Attributes.Policy // empty')
  kms=$(echo "$attrs" | jq -r '.Attributes.KmsMasterKeyId // empty')
  displayName=$(echo "$attrs" | jq -r '.Attributes.DisplayName // empty')

  if [ -n "$kms" ]; then
    echo "  KMS key configured: $kms" >> "$REPORT_FILE"
  else
    echo "  No KMS key configured for topic" >> "$REPORT_FILE"
    send_slack_alert "SNS Alert: Topic $arn has no KMS encryption configured"
  fi

  # check policy for wildcard principals or public access
  if [ -n "$policy" ] && [ "$policy" != "null" ]; then
    if echo "$policy" | jq -e '.Statement[]? | select(.Principal=="*")' >/dev/null 2>&1; then
      echo "  POLICY_ALLOW_WILDCARD_PRINCIPAL" >> "$REPORT_FILE"
      send_slack_alert "SNS Alert: Topic $arn policy contains wildcard principal"
    fi
    if echo "$policy" | jq -e '.Statement[]? | select(.Effect=="Allow" and (.Condition? // {} | length == 0) and .Principal!=null and (.Principal=="*") )' >/dev/null 2>&1; then
      echo "  POLICY_POTENTIALLY_PUBLIC_ALLOW" >> "$REPORT_FILE"
      send_slack_alert "SNS Alert: Topic $arn may allow public publish/actions"
    fi
  else
    echo "  No policy set or unable to read policy" >> "$REPORT_FILE"
  fi

  # subscriptions
  subs=$(aws sns list-subscriptions-by-topic --topic-arn "$arn" --output json 2>/dev/null || echo '{"Subscriptions":[]}')
  echo "$subs" | jq -c '.Subscriptions[]? // empty' | while read -r s; do
    protocol=$(echo "$s" | jq -r '.Protocol')
    endpoint=$(echo "$s" | jq -r '.Endpoint // ""')
    subarn=$(echo "$s" | jq -r '.SubscriptionArn // ""')
    echo "  Subscription: protocol=$protocol endpoint=$endpoint arn=$subarn" >> "$REPORT_FILE"

    # flag HTTP(S) endpoints that are not using HTTPS
    if [ "$protocol" = "http" ]; then
      echo "    INSECURE_HTTP_SUBSCRIPTION" >> "$REPORT_FILE"
      send_slack_alert "SNS Alert: Topic $arn has HTTP subscription to $endpoint (not HTTPS)"
    fi
  done

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  aws sns list-topics --output json 2>/dev/null | jq -c '.Topics[]? // empty' | while read -r t; do
    arn=$(echo "$t" | jq -r '.TopicArn')
    check_topic "$arn"
  done

  log_message "SNS topic audit written to $REPORT_FILE"
}

main "$@"

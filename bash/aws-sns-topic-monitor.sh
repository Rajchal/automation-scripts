#!/bin/bash

################################################################################
# AWS SNS Topic Monitor
# Monitors SNS topics for delivery failures, subscription status, and access policies
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/sns-monitor-$(date +%s).txt"
LOG_FILE="/var/log/sns-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
FAILED_DELIVERY_THRESHOLD="${FAILED_DELIVERY_THRESHOLD:-10}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || true; }
start_window() { date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%SZ; }
now_window() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# API wrappers
list_topics() {
  aws sns list-topics \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_topic_attrs() {
  local arn="$1"
  aws sns get-topic-attributes \
    --topic-arn "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_subscriptions_for_topic() {
  local arn="$1"
  aws sns list-subscriptions-by-topic \
    --topic-arn "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metric() {
  local topic_name="$1"; local metric="$2"; local stat="${3:-Sum}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/SNS \
    --metric-name "${metric}" \
    --dimensions Name=TopicName,Value="${topic_name}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].'${stat} \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{if(n>0) printf("%.0f", sum/n); else print "0"}'
}

write_header() {
  {
    echo "AWS SNS Topic Monitoring Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "Failed Delivery Threshold: ${FAILED_DELIVERY_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_topics() {
  log_message INFO "Listing SNS topics"
  {
    echo "=== TOPICS ==="
  } >> "${OUTPUT_FILE}"

  local total=0 encrypted=0 unencrypted=0 high_failure=0

  local topics_json
  topics_json=$(list_topics)
  echo "${topics_json}" | jq -r '.Topics[]?.TopicArn' 2>/dev/null | while read -r arn; do
    ((total++))
    local attrs
    attrs=$(get_topic_attrs "${arn}")

    local name display_name owner kms_key policy subscriptions_confirmed subscriptions_pending subscriptions_deleted
    name=$(basename "${arn}")
    display_name=$(echo "${attrs}" | jq_safe '.Attributes.DisplayName')
    owner=$(echo "${attrs}" | jq_safe '.Attributes.Owner')
    kms_key=$(echo "${attrs}" | jq_safe '.Attributes.KmsMasterKeyId')
    policy=$(echo "${attrs}" | jq_safe '.Attributes.Policy')
    subscriptions_confirmed=$(echo "${attrs}" | jq_safe '.Attributes.SubscriptionsConfirmed')
    subscriptions_pending=$(echo "${attrs}" | jq_safe '.Attributes.SubscriptionsPending')
    subscriptions_deleted=$(echo "${attrs}" | jq_safe '.Attributes.SubscriptionsDeleted')

    # Get metrics
    local published failed
    published=$(get_metric "${name}" "NumberOfMessagesPublished" "Sum" || echo "0")
    failed=$(get_metric "${name}" "NumberOfNotificationsFailed" "Sum" || echo "0")

    {
      echo "Topic: ${name}"
      echo "  ARN: ${arn}"
      echo "  Display Name: ${display_name}"
      echo "  Owner: ${owner}"
      echo "  Subscriptions (Confirmed): ${subscriptions_confirmed}"
      echo "  Subscriptions (Pending): ${subscriptions_pending}"
      echo "  Subscriptions (Deleted): ${subscriptions_deleted}"
      echo "  Messages Published (${DAYS_BACK}d avg): ${published}"
      echo "  Delivery Failures (${DAYS_BACK}d avg): ${failed}"
    } >> "${OUTPUT_FILE}"

    if [[ -n "${kms_key}" && "${kms_key}" != "null" && "${kms_key}" != "" ]]; then
      echo "  Encryption: ENABLED (${kms_key})" >> "${OUTPUT_FILE}"
      ((encrypted++))
    else
      echo "  Encryption: DISABLED" >> "${OUTPUT_FILE}"
      ((unencrypted++))
    fi

    # Flags
    if (( failed >= FAILED_DELIVERY_THRESHOLD )); then
      ((high_failure++))
      echo "  WARNING: High delivery failures (${failed} >= ${FAILED_DELIVERY_THRESHOLD})" >> "${OUTPUT_FILE}"
    fi

    if [[ "${subscriptions_pending}" != "0" ]]; then
      echo "  INFO: ${subscriptions_pending} subscriptions pending confirmation" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Topic Summary:"
    echo "  Total Topics: ${total}"
    echo "  Encrypted: ${encrypted}"
    echo "  Unencrypted: ${unencrypted}"
    echo "  High Failures: ${high_failure}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_subscriptions() {
  log_message INFO "Analyzing subscriptions"
  {
    echo "=== SUBSCRIPTIONS ==="
  } >> "${OUTPUT_FILE}"

  local total_subs=0 confirmed=0 pending=0

  local topics_json
  topics_json=$(list_topics)
  echo "${topics_json}" | jq -r '.Topics[]?.TopicArn' 2>/dev/null | while read -r arn; do
    local name subs_json
    name=$(basename "${arn}")
    subs_json=$(list_subscriptions_for_topic "${arn}")

    echo "${subs_json}" | jq -c '.Subscriptions[]?' 2>/dev/null | while read -r sub; do
      ((total_subs++))
      local protocol endpoint status sub_arn
      protocol=$(echo "${sub}" | jq_safe '.Protocol')
      endpoint=$(echo "${sub}" | jq_safe '.Endpoint')
      status=$(echo "${sub}" | jq_safe '.SubscriptionArn')
      sub_arn=$(echo "${sub}" | jq_safe '.SubscriptionArn')

      {
        echo "Topic: ${name}"
        echo "  Protocol: ${protocol}"
        echo "  Endpoint: ${endpoint}"
      } >> "${OUTPUT_FILE}"

      if [[ "${sub_arn}" == "PendingConfirmation" ]]; then
        ((pending++))
        echo "  Status: PENDING CONFIRMATION" >> "${OUTPUT_FILE}"
      else
        ((confirmed++))
        echo "  Status: CONFIRMED" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Subscription Summary:"
    echo "  Total: ${total_subs}"
    echo "  Confirmed: ${confirmed}"
    echo "  Pending: ${pending}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_policies() {
  log_message INFO "Auditing topic policies for public access"
  {
    echo "=== POLICY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local topics_json public_access=0
  topics_json=$(list_topics)
  echo "${topics_json}" | jq -r '.Topics[]?.TopicArn' 2>/dev/null | while read -r arn; do
    local attrs policy name
    attrs=$(get_topic_attrs "${arn}")
    policy=$(echo "${attrs}" | jq_safe '.Attributes.Policy')
    name=$(basename "${arn}")

    if [[ -z "${policy}" || "${policy}" == "null" ]]; then
      {
        echo "Topic: ${name}"
        echo "  Policy: none"
        echo ""
      } >> "${OUTPUT_FILE}"
      continue
    fi

    local public
    public=$(echo "${policy}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*" or .Principal.Service=="*"))' 2>/dev/null | wc -l)

    {
      echo "Topic: ${name}"
      echo "  Policy: present"
    } >> "${OUTPUT_FILE}"

    if (( public > 0 )); then
      ((public_access++))
      echo "  WARNING: Policy allows public access" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Policy Summary:"
    echo "  Topics with public access: ${public_access}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_firehose_subscriptions() {
  log_message INFO "Checking Firehose subscriptions"
  {
    echo "=== FIREHOSE SUBSCRIPTIONS ==="
  } >> "${OUTPUT_FILE}"

  local firehose_count=0
  local topics_json
  topics_json=$(list_topics)
  echo "${topics_json}" | jq -r '.Topics[]?.TopicArn' 2>/dev/null | while read -r arn; do
    local name subs_json
    name=$(basename "${arn}")
    subs_json=$(list_subscriptions_for_topic "${arn}")

    local count
    count=$(echo "${subs_json}" | jq '[.Subscriptions[]? | select(.Protocol=="firehose")] | length' 2>/dev/null || echo 0)
    
    if (( count > 0 )); then
      ((firehose_count++))
      {
        echo "Topic: ${name}"
        echo "  Firehose Subscriptions: ${count}"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Firehose Summary:"
    echo "  Topics with Firehose: ${firehose_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local failures="$2"; local pending="$3"; local unencrypted="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS SNS Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Topics", "value": "${total}", "short": true},
        {"title": "High Failures", "value": "${failures}", "short": true},
        {"title": "Pending Subs", "value": "${pending}", "short": true},
        {"title": "Unencrypted", "value": "${unencrypted}", "short": true},
        {"title": "Failure Threshold", "value": "${FAILED_DELIVERY_THRESHOLD}", "short": true},
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
  log_message INFO "Starting AWS SNS monitoring"
  write_header
  report_topics
  report_subscriptions
  audit_policies
  check_firehose_subscriptions
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local total failures pending unencrypted
  total=$(list_topics | jq '.Topics | length' 2>/dev/null || echo 0)
  failures=$(grep -c "High delivery failures" "${OUTPUT_FILE}" || echo 0)
  pending=$(grep -c "PENDING CONFIRMATION" "${OUTPUT_FILE}" || echo 0)
  unencrypted=$(grep -c "Encryption: DISABLED" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${total}" "${failures}" "${pending}" "${unencrypted}"
  cat "${OUTPUT_FILE}"
}

main "$@"

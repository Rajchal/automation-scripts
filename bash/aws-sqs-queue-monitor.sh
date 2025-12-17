#!/bin/bash

################################################################################
# AWS SQS Queue Monitor
# Monitors SQS queues for backlog, age, DLQ redrive, and throughput
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/sqs-monitor-$(date +%s).txt"
LOG_FILE="/var/log/sqs-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MAX_AGE_WARN_SECONDS="${MAX_AGE_WARN_SECONDS:-300}"      # max age allowed in seconds
MAX_INFLIGHT_WARN="${MAX_INFLIGHT_WARN:-1000}"           # inflight messages threshold
MAX_BACKLOG_WARN="${MAX_BACKLOG_WARN:-5000}"             # visible messages threshold
DLQ_REDIVE_WARN="${DLQ_REDIVE_WARN:-10}"                 # messages in DLQ threshold

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

list_queues() {
  aws sqs list-queues --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_queue_attrs() {
  local qurl="$1"
  aws sqs get-queue-attributes \
    --queue-url "${qurl}" \
    --attribute-names All \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS SQS Queue Monitoring Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Backlog Warn: ${MAX_BACKLOG_WARN} msgs"
    echo "InFlight Warn: ${MAX_INFLIGHT_WARN} msgs"
    echo "Max Age Warn: ${MAX_AGE_WARN_SECONDS}s"
    echo "DLQ Redrive Warn: ${DLQ_REDIVE_WARN} msgs"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_queues() {
  log_message INFO "Listing SQS queues"
  {
    echo "=== QUEUES ==="
  } >> "${OUTPUT_FILE}"

  local total=0 backlog_warn=0 age_warn=0 dlq_warn=0 inflight_warn=0 fifo_count=0

  local queues_json
  queues_json=$(list_queues)
  echo "${queues_json}" | jq -r '.QueueUrls[]?' 2>/dev/null | while read -r qurl; do
    ((total++))
    local attrs
    attrs=$(get_queue_attrs "${qurl}")

    local name messages inflight delayed not_visible oldest timestamp created fifo dlq_arn dlq_msgs policy redrive max_receive
    name=$(basename "${qurl}")
    messages=$(echo "${attrs}" | jq_safe '.Attributes.ApproximateNumberOfMessages')
    inflight=$(echo "${attrs}" | jq_safe '.Attributes.ApproximateNumberOfMessagesNotVisible')
    delayed=$(echo "${attrs}" | jq_safe '.Attributes.ApproximateNumberOfMessagesDelayed')
    not_visible=${inflight}
    created=$(echo "${attrs}" | jq_safe '.Attributes.CreatedTimestamp')
    oldest=$(echo "${attrs}" | jq_safe '.Attributes.ApproximateAgeOfOldestMessage')
    fifo=$(echo "${attrs}" | jq_safe '.Attributes.FifoQueue')
    dlq_arn=$(echo "${attrs}" | jq_safe '.Attributes.RedrivePolicy' | jq -r '.deadLetterTargetArn' 2>/dev/null || echo "")
    max_receive=$(echo "${attrs}" | jq_safe '.Attributes.RedrivePolicy' | jq -r '.maxReceiveCount' 2>/dev/null || echo "")
    policy=$(echo "${attrs}" | jq_safe '.Attributes.Policy')

    if [[ "${fifo}" == "true" ]]; then
      ((fifo_count++))
    fi

    # DLQ redrive stats (if DLQ configured)
    dlq_msgs=0
    if [[ -n "${dlq_arn}" && "${dlq_arn}" != "null" ]]; then
      local dlq_url
      dlq_url=$(aws sqs get-queue-url --queue-name "${dlq_arn##*:}" --region "${REGION}" --query 'QueueUrl' --output text 2>/dev/null || true)
      if [[ -n "${dlq_url}" ]]; then
        dlq_msgs=$(aws sqs get-queue-attributes --queue-url "${dlq_url}" --attribute-names ApproximateNumberOfMessages --region "${REGION}" --query 'Attributes.ApproximateNumberOfMessages' --output text 2>/dev/null || echo 0)
      fi
    fi

    {
      echo "Queue: ${name}"
      echo "  URL: ${qurl}"
      echo "  FIFO: ${fifo}"
      echo "  Messages Visible: ${messages}"
      echo "  Messages Inflight: ${inflight}"
      echo "  Messages Delayed: ${delayed}"
      echo "  Oldest Age: ${oldest}s"
      echo "  Created: $(date -d @${created} '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo ${created})"
    } >> "${OUTPUT_FILE}"

    if [[ -n "${dlq_arn}" && "${dlq_arn}" != "null" ]]; then
      echo "  DLQ: ${dlq_arn} (maxReceive=${max_receive})" >> "${OUTPUT_FILE}"
      echo "  DLQ Messages: ${dlq_msgs}" >> "${OUTPUT_FILE}"
    fi

    # Flags
    if (( messages >= MAX_BACKLOG_WARN )); then
      ((backlog_warn++))
      echo "  WARNING: Backlog high (${messages} >= ${MAX_BACKLOG_WARN})" >> "${OUTPUT_FILE}"
    fi
    if (( inflight >= MAX_INFLIGHT_WARN )); then
      ((inflight_warn++))
      echo "  WARNING: Inflight high (${inflight} >= ${MAX_INFLIGHT_WARN})" >> "${OUTPUT_FILE}"
    fi
    if (( oldest >= MAX_AGE_WARN_SECONDS )); then
      ((age_warn++))
      echo "  WARNING: Oldest message age high (${oldest}s >= ${MAX_AGE_WARN_SECONDS}s)" >> "${OUTPUT_FILE}"
    fi
    if (( dlq_msgs >= DLQ_REDIVE_WARN )); then
      ((dlq_warn++))
      echo "  WARNING: DLQ messages high (${dlq_msgs} >= ${DLQ_REDIVE_WARN})" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Queue Summary:"
    echo "  Total Queues: ${total}"
    echo "  FIFO Queues: ${fifo_count}"
    echo "  High Backlog: ${backlog_warn}"
    echo "  High Inflight: ${inflight_warn}"
    echo "  High Age: ${age_warn}"
    echo "  High DLQ: ${dlq_warn}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_policies() {
  log_message INFO "Checking queue policies for public access"
  {
    echo "=== POLICY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local queues_json
  queues_json=$(list_queues)
  echo "${queues_json}" | jq -r '.QueueUrls[]?' 2>/dev/null | while read -r qurl; do
    local attrs policy name
    attrs=$(get_queue_attrs "${qurl}")
    policy=$(echo "${attrs}" | jq_safe '.Attributes.Policy')
    name=$(basename "${qurl}")

    if [[ -z "${policy}" || "${policy}" == "null" ]]; then
      {
        echo "Queue: ${name}"
        echo "  Policy: none"
        echo "" 
      } >> "${OUTPUT_FILE}"
      continue
    fi

    local public
    public=$(echo "${policy}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*"))' 2>/dev/null | wc -l)

    {
      echo "Queue: ${name}"
      echo "  Policy present"
    } >> "${OUTPUT_FILE}"

    if (( public > 0 )); then
      echo "  WARNING: Policy allows public access" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local total="$1"; local backlog="$2"; local age="$3"; local dlq="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS SQS Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Queues", "value": "${total}", "short": true},
        {"title": "High Backlog", "value": "${backlog}", "short": true},
        {"title": "Oldest Age Warn", "value": "${age}", "short": true},
        {"title": "High DLQ", "value": "${dlq}", "short": true},
        {"title": "Backlog Warn", "value": "${MAX_BACKLOG_WARN}", "short": true},
        {"title": "Age Warn", "value": "${MAX_AGE_WARN_SECONDS}s", "short": true},
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
  log_message INFO "Starting AWS SQS monitoring"
  write_header
  report_queues
  report_policies
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local total backlog age dlq
  total=$(list_queues | jq '.QueueUrls | length' 2>/dev/null || echo 0)
  backlog=$(grep -c "Backlog high" "${OUTPUT_FILE}" || echo 0)
  age=$(grep -c "Oldest message age high" "${OUTPUT_FILE}" || echo 0)
  dlq=$(grep -c "DLQ messages high" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${total}" "${backlog}" "${age}" "${dlq}"
  cat "${OUTPUT_FILE}"
}

main "$@"

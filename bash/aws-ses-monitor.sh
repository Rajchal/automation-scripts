#!/bin/bash

################################################################################
# AWS SES Monitor
# Monitors SES verified identities, sending quotas/stats, and recent bounces/complaints
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ses-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-ses-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
BOUNCE_WARN_THRESHOLD="${BOUNCE_WARN_THRESHOLD:-5}"
COMPLAINT_WARN_THRESHOLD="${COMPLAINT_WARN_THRESHOLD:-3}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_identities() {
  aws ses list-identities --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_identity_verification() {
  local id="$1"
  aws ses get-identity-verification-attributes --identities "${id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_send_quota() {
  aws ses get-send-quota --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_send_stats() {
  aws ses get-send-statistics --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_cloudwatch_metric() {
  local namespace="$1"; local metric="$2"; local period="$3"; local stat="$4"
  aws cloudwatch get-metric-statistics --namespace "${namespace}" --metric-name "${metric}" --start-time "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period "${period}" --statistics "${stat}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS SES Monitor Report"
    echo "======================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Bounce Warn Threshold: ${BOUNCE_WARN_THRESHOLD}"
    echo "Complaint Warn Threshold: ${COMPLAINT_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_identities() {
  log_message INFO "Listing SES identities"
  echo "=== SES Identities ===" >> "${OUTPUT_FILE}"

  local ids
  ids=$(list_identities)

  echo "${ids}" | jq -r '.Identities[]?' 2>/dev/null | while read -r id; do
    echo "Identity: ${id}" >> "${OUTPUT_FILE}"
    local ver
    ver=$(get_identity_verification "${id}")
    local status
    status=$(echo "${ver}" | jq_safe ".VerificationAttributes.\"${id}\".VerificationStatus")
    echo "  VerificationStatus: ${status}" >> "${OUTPUT_FILE}"

    # Check if domain or email
    if [[ "${id}" == *"@"* ]]; then
      echo "  Type: Email Address" >> "${OUTPUT_FILE}"
    else
      echo "  Type: Domain" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

audit_quota_and_stats() {
  log_message INFO "Fetching SES send quota and statistics"
  echo "=== SES Quota & Stats ===" >> "${OUTPUT_FILE}"

  local quota
  quota=$(get_send_quota)
  local max_send_rate sent_last_24h sent_last_15d
  max_send_rate=$(echo "${quota}" | jq_safe '.MaxSendRate')
  sent_last_24h=$(echo "${quota}" | jq_safe '.SentLast24Hours')
  echo "  MaxSendRate: ${max_send_rate}" >> "${OUTPUT_FILE}"
  echo "  SentLast24Hours: ${sent_last_24h}" >> "${OUTPUT_FILE}"

  local stats
  stats=$(get_send_stats)
  echo "  SendStatistics Points: " >> "${OUTPUT_FILE}"
  echo "${stats}" | jq -c '.SendDataPoints[]?' 2>/dev/null | while read -r p; do
    local ts
    ts=$(echo "${p}" | jq_safe '.Timestamp')
    local deliveries bounces complaints rejects
    deliveries=$(echo "${p}" | jq_safe '.DeliveryAttempts')
    bounces=$(echo "${p}" | jq_safe '.Bounces')
    complaints=$(echo "${p}" | jq_safe '.Complaints')
    rejects=$(echo "${p}" | jq_safe '.Rejects')
    echo "    - ${ts}: deliveries=${deliveries}, bounces=${bounces}, complaints=${complaints}, rejects=${rejects}" >> "${OUTPUT_FILE}"
  done
  echo "" >> "${OUTPUT_FILE}"
}

audit_bounces_complaints() {
  log_message INFO "Checking CloudWatch metrics for bounces/complaints (last 24h)"
  echo "=== SES CloudWatch Metrics (24h) ===" >> "${OUTPUT_FILE}"

  local bounces metrics_bounces complaints metrics_complaints
  metrics_bounces=$(get_cloudwatch_metric "AWS/SES" "Bounce" 300 "Sum")
  metrics_complaints=$(get_cloudwatch_metric "AWS/SES" "Complaint" 300 "Sum")

  bounces=$(echo "${metrics_bounces}" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  complaints=$(echo "${metrics_complaints}" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')

  echo "  Bounces (24h sum): ${bounces}" >> "${OUTPUT_FILE}"
  echo "  Complaints (24h sum): ${complaints}" >> "${OUTPUT_FILE}"

  if (( ${bounces:-0} >= BOUNCE_WARN_THRESHOLD )); then
    echo "  WARNING: High bounce count in last 24h: ${bounces}" >> "${OUTPUT_FILE}"
  fi
  if (( ${complaints:-0} >= COMPLAINT_WARN_THRESHOLD )); then
    echo "  WARNING: High complaint count in last 24h: ${complaints}" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local bounces="$1"; local complaints="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  if (( bounces >= BOUNCE_WARN_THRESHOLD || complaints >= COMPLAINT_WARN_THRESHOLD )); then
    color="warning"
  fi

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS SES Monitor Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Bounces (24h)", "value": "${bounces}", "short": true},
        {"title": "Complaints (24h)", "value": "${complaints}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
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
  log_message INFO "Starting SES monitor"
  write_header
  audit_identities
  audit_quota_and_stats
  audit_bounces_complaints
  log_message INFO "SES monitor complete. Report: ${OUTPUT_FILE}"

  local bounces complaints
  bounces=$(grep "Bounces (24h sum):" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  complaints=$(grep "Complaints (24h sum):" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${bounces}" "${complaints}"
  cat "${OUTPUT_FILE}"
}

main "$@"

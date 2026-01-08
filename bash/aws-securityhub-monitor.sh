#!/bin/bash

################################################################################
# AWS Security Hub Monitor
# Summarizes Security Hub findings (counts by severity/status), lists recent
# critical/high findings and optionally posts alerts to Slack.
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/securityhub-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-securityhub-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
CRITICAL_WARN_THRESHOLD="${CRITICAL_WARN_THRESHOLD:-1}"
HIGH_WARN_THRESHOLD="${HIGH_WARN_THRESHOLD:-5}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_findings() {
  aws securityhub get-findings --region "${REGION}" --filters "$1" --max-results 100 --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Security Hub Monitor Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Critical Warn Threshold: ${CRITICAL_WARN_THRESHOLD}"
    echo "High Warn Threshold: ${HIGH_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

summary_findings() {
  log_message INFO "Fetching findings summary"
  echo "=== Findings Summary ===" >> "${OUTPUT_FILE}"

  # total counts by severity
  local total
  total=$(aws securityhub get-findings --region "${REGION}" --max-results 1 --query 'length(Findings)') || total=0

  # Use filters for counts per severity
  for sev in CRITICAL HIGH MEDIUM LOW INFORMATIONAL; do
    local count
    count=$(aws securityhub get-findings --region "${REGION}" --filters "{\"SeverityLabel\": [{\"Value\": \"${sev}\", \"Comparison\": \"EQUALS\"}]}" --query 'length(Findings)' --output text 2>/dev/null || echo 0)
    echo "  ${sev}: ${count}" >> "${OUTPUT_FILE}"
  done

  echo "" >> "${OUTPUT_FILE}"
}

recent_critical_high() {
  log_message INFO "Listing recent critical/high findings (last 24h)"
  echo "=== Recent Critical/High Findings (24h) ===" >> "${OUTPUT_FILE}"

  local since
  since=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

  local filter
  filter="{\"SeverityLabel\":[{\"Value\":\"CRITICAL\",\"Comparison\":\"EQUALS\"},{\"Value\":\"HIGH\",\"Comparison\":\"EQUALS\"}],\"RecordState\":[{\"Value\":\"ACTIVE\",\"Comparison\":\"EQUALS\"}],\"CreatedAt\":[{\"Start\":\"${since}\"}]}"

  local findings
  findings=$(list_findings "${filter}")

  echo "${findings}" | jq -c '.Findings[]?' 2>/dev/null | while read -r f; do
    local id title severity resource time
    id=$(echo "${f}" | jq_safe '.Id')
    title=$(echo "${f}" | jq_safe '.Title')
    severity=$(echo "${f}" | jq_safe '.Severity.Label')
    resource=$(echo "${f}" | jq_safe '.Resources[0].Id')
    time=$(echo "${f}" | jq_safe '.CreatedAt')
    echo "- ${time} | ${severity} | ${id} | ${title} | resource=${resource}" >> "${OUTPUT_FILE}"
  done

  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local critical_count="$1"; local high_count="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  if (( critical_count >= CRITICAL_WARN_THRESHOLD )); then
    color="danger"
  elif (( high_count >= HIGH_WARN_THRESHOLD )); then
    color="warning"
  fi

  local payload
  payload=$(cat <<EOF
{
  "text": "Security Hub Summary",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Critical Findings (24h)", "value": "${critical_count}", "short": true},
        {"title": "High Findings (24h)", "value": "${high_count}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting Security Hub monitor"
  write_header
  summary_findings
  recent_critical_high

  # compute simple counts for Slack
  local critical_count high_count
  critical_count=$(aws securityhub get-findings --region "${REGION}" --filters "{\"SeverityLabel\": [{\"Value\": \"CRITICAL\", \"Comparison\": \"EQUALS\"}], \"CreatedAt\": [{\"Start\": \"$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)\"}]}" --query 'length(Findings)' --output text 2>/dev/null || echo 0)
  high_count=$(aws securityhub get-findings --region "${REGION}" --filters "{\"SeverityLabel\": [{\"Value\": \"HIGH\", \"Comparison\": \"EQUALS\"}], \"CreatedAt\": [{\"Start\": \"$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)\"}]}" --query 'length(Findings)' --output text 2>/dev/null || echo 0)

  send_slack_alert "${critical_count}" "${high_count}"
  log_message INFO "Security Hub monitor complete. Report: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

#!/bin/bash

################################################################################
# AWS Security Hub Findings Monitor
# Aggregates Security Hub findings by severity, product, and resource, and alerts
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/security-hub-findings-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-security-hub-findings-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
CRITICAL_WARN_THRESHOLD="${CRITICAL_WARN_THRESHOLD:-1}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_findings() {
  aws securityhub get-findings --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Security Hub Findings Monitor"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Critical Warn Threshold: ${CRITICAL_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_findings() {
  log_message INFO "Fetching Security Hub findings"
  echo "=== Security Hub Findings ===" >> "${OUTPUT_FILE}"

  local data
  data=$(list_findings)

  local total
  total=$(echo "${data}" | jq '.Findings | length' 2>/dev/null || echo 0)
  echo "Total Findings: ${total}" >> "${OUTPUT_FILE}"

  # Counts by severity label
  echo "Findings by Severity:" >> "${OUTPUT_FILE}"
  echo "${data}" | jq -r '.Findings[]? | .Severity.Label' 2>/dev/null | sort | uniq -c | awk '{print "  " $2 ": " $1}' >> "${OUTPUT_FILE}"

  # Top products
  echo "" >> "${OUTPUT_FILE}"
  echo "Top Products:" >> "${OUTPUT_FILE}"
  echo "${data}" | jq -r '.Findings[]? | .ProductName' 2>/dev/null | sort | uniq -c | sort -rn | head -n 10 | awk '{print "  " $2 ": " $1}' >> "${OUTPUT_FILE}"

  # Top resources
  echo "" >> "${OUTPUT_FILE}"
  echo "Top Affected Resources (by count):" >> "${OUTPUT_FILE}"
  echo "${data}" | jq -r '.Findings[]? | .Resources[]? | (.Type + ":" + (.Id // ""))' 2>/dev/null | sort | uniq -c | sort -rn | head -n 10 | awk '{print "  " $2 ": " $1}' >> "${OUTPUT_FILE}"

  # List critical/high findings details
  echo "" >> "${OUTPUT_FILE}"
  echo "Critical / High Findings:" >> "${OUTPUT_FILE}"
  echo "${data}" | jq -c '.Findings[]? | select(.Severity.Label=="CRITICAL" or .Severity.Label=="HIGH")' 2>/dev/null | while read -r f; do
    local id sev title product
    id=$(echo "${f}" | jq_safe '.Id')
    sev=$(echo "${f}" | jq_safe '.Severity.Label')
    title=$(echo "${f}" | jq_safe '.Title')
    product=$(echo "${f}" | jq_safe '.ProductName')
    echo "- ${id}: [${sev}] ${title} (${product})" >> "${OUTPUT_FILE}"
  done

  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local critical_count="$1"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( critical_count >= CRITICAL_WARN_THRESHOLD )) && color="danger"

  local payload
  payload=$(cat <<EOF
{
  "text": "Security Hub Findings Summary",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Critical Findings", "value": "${critical_count}", "short": true},
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
  log_message INFO "Starting Security Hub findings monitor"
  write_header
  audit_findings
  log_message INFO "Security Hub monitor complete. Report saved to: ${OUTPUT_FILE}"

  local critical
  critical=$(grep "CRITICAL" -c "${OUTPUT_FILE}" 2>/dev/null || echo 0)
  send_slack_alert "${critical}"
  cat "${OUTPUT_FILE}"
}

main "$@"

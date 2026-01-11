#!/bin/bash

################################################################################
# AWS Security Hub Monitor
# Summarizes Security Hub findings by severity and reports new critical/high findings
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/security-hub-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-security-hub-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
NEW_FINDINGS_WINDOW_HOURS="${NEW_FINDINGS_WINDOW_HOURS:-24}"
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
  aws securityhub get-findings --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Security Hub Monitor Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "New findings window (hours): ${NEW_FINDINGS_WINDOW_HOURS}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_findings() {
  log_message INFO "Querying Security Hub findings"
  echo "=== Security Hub Findings Summary ===" >> "${OUTPUT_FILE}"

  local findings
  findings=$(list_findings)

  # totals by severity
  local total critical high medium low info
  total=$(echo "${findings}" | jq '.Findings | length' 2>/dev/null || echo 0)
  critical=$(echo "${findings}" | jq '[.Findings[]? | select(.Severity.Label=="CRITICAL")] | length' 2>/dev/null || echo 0)
  high=$(echo "${findings}" | jq '[.Findings[]? | select(.Severity.Label=="HIGH")] | length' 2>/dev/null || echo 0)
  medium=$(echo "${findings}" | jq '[.Findings[]? | select(.Severity.Label=="MEDIUM")] | length' 2>/dev/null || echo 0)
  low=$(echo "${findings}" | jq '[.Findings[]? | select(.Severity.Label=="LOW")] | length' 2>/dev/null || echo 0)
  info=$(echo "${findings}" | jq '[.Findings[]? | select(.Severity.Label=="INFORMATIONAL" or .Severity.Label=="INFORMATION")] | length' 2>/dev/null || echo 0)

  echo "  Total findings: ${total}" >> "${OUTPUT_FILE}"
  echo "    CRITICAL: ${critical}" >> "${OUTPUT_FILE}"
  echo "    HIGH: ${high}" >> "${OUTPUT_FILE}"
  echo "    MEDIUM: ${medium}" >> "${OUTPUT_FILE}"
  echo "    LOW: ${low}" >> "${OUTPUT_FILE}"
  echo "    INFO: ${info}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  # top 10 recent critical/high findings
  echo "=== Top Recent CRITICAL/HIGH Findings (10) ===" >> "${OUTPUT_FILE}"
  echo "${findings}" | jq -c '.Findings[]? | select(.Severity.Label=="CRITICAL" or .Severity.Label=="HIGH")' 2>/dev/null | head -n 10 | while read -r f; do
    local id title severity resource created
    id=$(echo "${f}" | jq_safe '.Id')
    title=$(echo "${f}" | jq_safe '.Title')
    severity=$(echo "${f}" | jq_safe '.Severity.Label')
    resource=$(echo "${f}" | jq -r '.Resources[0]?.Id' 2>/dev/null || echo '')
    created=$(echo "${f}" | jq_safe '.CreatedAt')
    echo "  - ${severity} | ${id} | ${title} | resource=${resource} | created=${created}" >> "${OUTPUT_FILE}"
  done
  echo "" >> "${OUTPUT_FILE}"

  # count new findings in window
  local window_start
  window_start=$(date -u -d "-${NEW_FINDINGS_WINDOW_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

  local new_critical new_high
  new_critical=$(echo "${findings}" | jq --arg ws "${window_start}" '[.Findings[]? | select((.Severity.Label=="CRITICAL") and (.CreatedAt >= $ws))] | length' 2>/dev/null || echo 0)
  new_high=$(echo "${findings}" | jq --arg ws "${window_start}" '[.Findings[]? | select((.Severity.Label=="HIGH") and (.CreatedAt >= $ws))] | length' 2>/dev/null || echo 0)

  echo "=== New Findings in last ${NEW_FINDINGS_WINDOW_HOURS}h ===" >> "${OUTPUT_FILE}"
  echo "  New CRITICAL: ${new_critical}" >> "${OUTPUT_FILE}"
  echo "  New HIGH: ${new_high}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  # If thresholds exceeded, add warnings
  if (( new_critical >= CRITICAL_WARN_THRESHOLD )); then
    echo "ALERT: ${new_critical} new CRITICAL findings in last ${NEW_FINDINGS_WINDOW_HOURS}h" >> "${OUTPUT_FILE}"
  fi
  if (( new_high >= HIGH_WARN_THRESHOLD )); then
    echo "ALERT: ${new_high} new HIGH findings in last ${NEW_FINDINGS_WINDOW_HOURS}h" >> "${OUTPUT_FILE}"
  fi

}

send_slack_alert() {
  local critical_count="$1"; local high_count="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  if (( critical_count > 0 )); then color="danger"; elif (( high_count > 0 )); then color="warning"; fi

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Security Hub Summary",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Critical Findings", "value": "${critical_count}", "short": true},
        {"title": "High Findings", "value": "${high_count}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Window (h)", "value": "${NEW_FINDINGS_WINDOW_HOURS}", "short": true}
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
  audit_findings
  log_message INFO "Security Hub monitoring complete. Report: ${OUTPUT_FILE}"

  local critical_count high_count
  critical_count=$(grep "CRITICAL:" "${OUTPUT_FILE}" | head -n1 | awk '{print $2}' 2>/dev/null || echo 0)
  high_count=$(grep "HIGH:" "${OUTPUT_FILE}" | head -n1 | awk '{print $2}' 2>/dev/null || echo 0)
  send_slack_alert "${critical_count}" "${high_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

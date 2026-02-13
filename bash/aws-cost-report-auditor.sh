#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cost-report-auditor.log"
REPORT_FILE="/tmp/cost-report-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
WINDOW_DAYS="${COST_WINDOW_DAYS:-7}"
COST_WARN_DOLLARS="${COST_WARN_DOLLARS:-100.00}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Cost Report Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Window days: $WINDOW_DAYS" >> "$REPORT_FILE"
  echo "Warn threshold: $${COST_WARN_DOLLARS}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  END=$(date +%Y-%m-%d)
  START=$(date -d "$WINDOW_DAYS days ago" +%Y-%m-%d)

  # Query Cost Explorer grouped by service; requires Cost Explorer enabled
  out=$(aws ce get-cost-and-usage --time-period Start=$START,End=$END --granularity DAILY --metrics "UnblendedCost" --group-by Type=DIMENSION,Key=SERVICE 2>/dev/null || true)

  if [ -z "$out" ] || [ "$out" = "" ]; then
    echo "Cost Explorer query failed or returned empty. Ensure Cost Explorer is enabled and IAM has permission." >> "$REPORT_FILE"
    log_message "Cost Explorer query failed"
    exit 0
  fi

  # produce service	amount lines and sum across time
  echo "Service	Amount" >> "$REPORT_FILE"
  echo "$out" | jq -r '.ResultsByTime[]?.Groups[]? | [.Keys[0], (.Metrics.UnblendedCost.Amount|tonumber)] | @tsv' | \
    awk -F"\t" '{arr[$1]+=$2} END{for (i in arr) printf "%s\t%.2f\n", i, arr[i]}' | sort -k2 -nr >> "$REPORT_FILE"

  # alert for expensive services
  echo "" >> "$REPORT_FILE"
  echo "Services exceeding threshold ($COST_WARN_DOLLARS):" >> "$REPORT_FILE"
  echo "$out" | jq -r '.ResultsByTime[]?.Groups[]? | [.Keys[0], (.Metrics.UnblendedCost.Amount|tonumber)] | @tsv' | \
    awk -F"\t" '{arr[$1]+=$2} END{for (i in arr) if (arr[i] >= '
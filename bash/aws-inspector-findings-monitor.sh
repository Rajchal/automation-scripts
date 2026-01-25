#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-inspector-findings-monitor.log"
REPORT_FILE="/tmp/inspector-findings-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_RESULTS="${INSPECTOR_MAX_RESULTS:-50}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "Inspector Findings Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Max results: $MAX_RESULTS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

is_high_severity() {
  local sev="$1"
  if echo "$sev" | grep -Eq '^[0-9]+$'; then
    [ "$sev" -ge 8 ] && return 0 || return 1
  fi
  case "${sev^^}" in
    HIGH|CRITICAL) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  write_header

  findings_json=$(aws inspector2 list-findings --max-results "$MAX_RESULTS" --region "$REGION" --output json 2>/dev/null || echo '{"findings":[]}')
  ids=$(echo "$findings_json" | jq -r '.findings[]?.id // .findings[]? | . ' 2>/dev/null || echo "")

  if [ -z "$ids" ]; then
    echo "No Inspector findings." >> "$REPORT_FILE"
    log_message "No Inspector findings in region $REGION"
    exit 0
  fi

  total=0
  high_count=0

  # `list-findings` output varies; iterate over items
  echo "$findings_json" | jq -c '.findings[]?' | while read -r item; do
    total=$((total+1))
    fid=$(echo "$item" | jq -r '.id // .findingArn // "<no-id>"')
    title=$(echo "$item" | jq -r '.title // .title // "<no-title>"')
    severity=$(echo "$item" | jq -r '.severity.label // .severity // "UNKNOWN"')
    created=$(echo "$item" | jq -r '.createdAt // .updatedAt // "<unknown>"')

    echo "Finding: $fid" >> "$REPORT_FILE"
    echo "Title: $title" >> "$REPORT_FILE"
    echo "Created: $created" >> "$REPORT_FILE"
    echo "Severity: $severity" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if is_high_severity "$severity"; then
      high_count=$((high_count+1))
      send_slack_alert "Inspector HIGH finding: $title ($fid) severity=$severity"
    fi
  done

  echo "Summary: total=$total, high=$high_count" >> "$REPORT_FILE"
  log_message "Inspector report written to $REPORT_FILE (total=$total, high=$high_count)"
}

main "$@"

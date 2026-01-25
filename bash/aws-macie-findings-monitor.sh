#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-macie-findings-monitor.log"
REPORT_FILE="/tmp/macie-findings-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_RESULTS="${MACIE_MAX_RESULTS:-50}"
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
  echo "Macie Findings Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Max results: $MAX_RESULTS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

is_high_severity() {
  local sev="$1"
  # Numeric severity considered high if >=8
  if echo "$sev" | grep -Eq '^[0-9]+$'; then
    [ "$sev" -ge 8 ] && return 0 || return 1
  fi
  # String label check
  case "${sev^^}" in
    HIGH|CRITICAL) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  write_header

  findings_list=$(aws macie2 list-findings --max-results "$MAX_RESULTS" --region "$REGION" --output json 2>/dev/null || echo '{"findingIds":[]}')
  ids=$(echo "$findings_list" | jq -r '.findingIds[]?' )

  if [ -z "$ids" ]; then
    echo "No recent Macie findings." >> "$REPORT_FILE"
    log_message "No Macie findings in region $REGION"
    exit 0
  fi

  high_count=0
  total=0

  for id in $ids; do
    total=$((total+1))
    details=$(aws macie2 get-findings --finding-ids "$id" --region "$REGION" --output json 2>/dev/null || echo '{"findings":[]}')
    finding=$(echo "$details" | jq -r '.findings[0] // {}')
    title=$(echo "$finding" | jq -r '.title // .type // "<no-title>"')
    created=$(echo "$finding" | jq -r '.createdAt // "<unknown>"')
    severity=$(echo "$finding" | jq -r '(.severity.label // .severity // "UNKNOWN")')

    echo "Finding: $id" >> "$REPORT_FILE"
    echo "Title: $title" >> "$REPORT_FILE"
    echo "Created: $created" >> "$REPORT_FILE"
    echo "Severity: $severity" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if is_high_severity "$severity"; then
      high_count=$((high_count+1))
      send_slack_alert "Macie HIGH finding: $title ($id) severity=$severity"
    fi
  done

  echo "Summary: total=$total, high=$high_count" >> "$REPORT_FILE"
  log_message "Macie report written to $REPORT_FILE (total=$total, high=$high_count)"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-macie-findings-monitor.log"
REPORT_FILE="/tmp/macie-findings-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
LOOKBACK_DAYS="${MACIE_LOOKBACK_DAYS:-7}"
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
  echo "Macie Findings Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Lookback days: $LOOKBACK_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  start_time=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)

  finding_ids=$(aws macie2 list-findings --region "$REGION" --finding-criteria "{\"createdAt\":{\"comparator\":\"GT\",\"values\":[{\"date\":\"$start_time\"}]}}" --max-results 50 --output text --query 'findingIds' 2>/dev/null || true)

  if [ -z "$finding_ids" ]; then
    echo "No Macie findings in the last $LOOKBACK_DAYS days." >> "$REPORT_FILE"
    log_message "No Macie findings in region $REGION since $start_time"
    exit 0
  fi

  # retrieve finding details
  findings_json=$(aws macie2 get-findings --region "$REGION" --finding-ids $(echo "$finding_ids" | tr '\n' ' ') --output json 2>/dev/null || echo '{}')

  total=$(echo "$findings_json" | jq '.findings | length')
  echo "Found $total findings in the last $LOOKBACK_DAYS days" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  high_count=0
  medium_count=0
  low_count=0

  for i in $(seq 0 $((total-1))); do
    f=$(echo "$findings_json" | jq ".findings[$i]")
    id=$(echo "$f" | jq -r '.id // "<nil>"')
    title=$(echo "$f" | jq -r '.title // .findingType // "<no-title>"')
    severity=$(echo "$f" | jq -r '.severity // "UNKNOWN"')
    severity_label=$(echo "$f" | jq -r '.severityDescription // .severity // "UNKNOWN"')
    resource=$(echo "$f" | jq -r '.resources[0].details // {} | tostring' 2>/dev/null || echo "")

    echo "ID: $id" >> "$REPORT_FILE"
    echo "Title: $title" >> "$REPORT_FILE"
    echo "Severity: $severity_label ($severity)" >> "$REPORT_FILE"
    echo "Resource: $resource" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    case "${severity_label^^}" in
      *HIGH*|*CRITICAL*) ((high_count++)) ;;
      *MEDIUM*) ((medium_count++)) ;;
      *LOW*) ((low_count++)) ;;
    esac

    if echo "$severity_label" | grep -qi "high\|critical"; then
      send_slack_alert "Macie HIGH finding: $title (ID: $id) — check $REGION"
    fi
  done

  echo "Summary:" >> "$REPORT_FILE"
  echo "  High: $high_count" >> "$REPORT_FILE"
  echo "  Medium: $medium_count" >> "$REPORT_FILE"
  echo "  Low: $low_count" >> "$REPORT_FILE"

  log_message "Macie report written to $REPORT_FILE (High: $high_count, Medium: $medium_count, Low: $low_count)"
}

main "$@"

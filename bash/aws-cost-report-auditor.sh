#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cost-report-auditor.log"
REPORT_FILE="/tmp/cost-report-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
COST_WARN_AMOUNT="${COST_WARN_AMOUNT:-1000}" # default USD
TOP_N="${COST_REPORT_TOP_N:-10}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Cost Report Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Report period: Last full month" >> "$REPORT_FILE"
  echo "Warn threshold: \">$${COST_WARN_AMOUNT}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

last_month_range() {
  START=$(date -d "$(date +%Y-%m-01) -1 month" +%Y-%m-01)
  END=$(date -d "$(date +%Y-%m-01)" +%Y-%m-01)
}

get_total_cost() {
  aws ce get-cost-and-usage --time-period Start="$START",End="$END" --granularity MONTHLY --metrics UnblendedCost --output json 2>/dev/null || true
}

report_top_services() {
  local json="$1"
  echo "Top ${TOP_N} services by cost:" >> "$REPORT_FILE"
  echo "$json" | jq -r '.ResultsByTime[0].Groups[]? | [.Keys[0], .Metrics.UnblendedCost.Amount] | @tsv' | sort -k2 -nr | head -n "$TOP_N" | awk -F"\t" '{printf "  %-30s %10s\n", $1, "$"$2}' >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header
  last_month_range

  out=$(get_total_cost)
  if [ -z "$out" ] || [ "$out" = "" ]; then
    echo "Cost Explorer query failed or returned empty. Ensure AWS Cost Explorer is enabled and permissions are configured." >> "$REPORT_FILE"
    log_message "Cost Explorer query failed"
    exit 1
  fi

  total=$(echo "$out" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Amount // "0"')
  currency=$(echo "$out" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Unit // "USD"')
  echo "Total cost for ${START} to ${END} : ${currency} ${total}" >> "$REPORT_FILE"

  # compare to threshold
  if command -v bc >/dev/null 2>&1; then
    cmp=$(echo "$total >= $COST_WARN_AMOUNT" | bc -l 2>/dev/null || echo 0)
    if [ "$cmp" -eq 1 ]; then
      send_slack_alert "Cost Alert: Total cost for ${START} to ${END} is ${currency} ${total} (>= ${COST_WARN_AMOUNT})"
    fi
  else
    # fallback integer compare
    total_int=${total%%.*}
    if [ "$total_int" -ge "$COST_WARN_AMOUNT" ]; then
      send_slack_alert "Cost Alert: Total cost for ${START} to ${END} is ${currency} ${total} (>= ${COST_WARN_AMOUNT})"
    fi
  fi

  # Top services
  report_top_services "$out"

  echo "Detailed JSON (raw):" >> "$REPORT_FILE"
  echo "$out" | jq '.' >> "$REPORT_FILE"

  log_message "Cost report written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cost-report-auditor.log"
REPORT_FILE="/tmp/cost-report-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
COST_THRESHOLD="${COST_THRESHOLD:-1000.00}"
PERIOD_DAYS="${COST_PERIOD_DAYS:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Cost Report Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Period days: $PERIOD_DAYS" >> "$REPORT_FILE"
  echo "Threshold (alert if >): $COST_THRESHOLD" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  end=$(date -u +%Y-%m-%d)
  start=$(date -u -d "${PERIOD_DAYS} days ago" +%Y-%m-%d)

  # Try using Cost Explorer (requires permissions and Cost Explorer enabled)
  out=$(aws ce get-cost-and-usage \
    --time-period Start=${start},End=${end} \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json 2>/dev/null || true)

  if [ -z "$out" ] || [ "$out" = "" ]; then
    echo "Cost data not available (Cost Explorer may be disabled or insufficient permissions)" >> "$REPORT_FILE"
    log_message "Cost data not available"
    exit 0
  fi

  total=$(echo "$out" | jq -r '.ResultsByTime[0].Total.UnblendedCost.Amount // "0"')
  if [ -z "$total" ] || [ "$total" = "null" ]; then
    total=0
  fi

  echo "Total cost (start=${start} end=${end}): $total" >> "$REPORT_FILE"

  # Top services
  echo "Top services:" >> "$REPORT_FILE"
  echo "$out" | jq -r '.ResultsByTime[0].Groups[]? | [.Keys[0], .Metrics.UnblendedCost.Amount] | @tsv' | sort -k2 -nr | head -n 10 | awk -F"\t" '{printf "  %s: %s\n", $1, $2}' >> "$REPORT_FILE"

  # alert if above threshold
  # use bc for float compare
  if [ $(echo "$total > $COST_THRESHOLD" | bc -l) -eq 1 ]; then
    send_slack_alert "Cost Alert: Total cost for ${start}..${end} = $total exceeds threshold $COST_THRESHOLD"
    echo "ALERT: total ($total) > threshold ($COST_THRESHOLD)" >> "$REPORT_FILE"
  fi

  log_message "Cost report written to $REPORT_FILE"
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-cost-report-auditor.log"
REPORT_FILE="/tmp/cost-report-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
LOOKBACK_DAYS="${COST_LOOKBACK_DAYS:-30}"
ALERT_PERCENT="${COST_ALERT_PERCENT:-30}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Cost Report Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "Lookback days: $LOOKBACK_DAYS" >> "$REPORT_FILE"
  echo "Alert percent threshold: $ALERT_PERCENT%" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

sum_by_service() {
  local start="$1"; local end="$2"
  aws ce get-cost-and-usage \
    --time-period Start=$start,End=$end \
    --granularity DAILY \
    --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json 2>/dev/null |
    jq -r '.ResultsByTime[]?.Groups[]? | [.Keys[0], (.Metrics.UnblendedCost.Amount|tonumber)] | @tsv' || echo ""
}

aggregate_period_total() {
  # input: TSV lines Service\tAmount
  awk -F"\t" '{a[$1]+=$2}END{for (i in a) printf "%s\t%.2f\n", i, a[i]}' | sort -k2nr
}

percent_change() {
  local prev="$1"; local curr="$2"
  if (( $(echo "$prev == 0" | bc -l) )); then
    if (( $(echo "$curr > 0" | bc -l) )); then
      echo "inf"
    else
      echo "0"
    fi
  else
    echo "$(awk -v p="$prev" -v c="$curr" 'BEGIN{printf "%.2f", (c-p)/p*100}')"
  fi
}

main() {
  write_header

  END=$(date -u +%Y-%m-%d)
  START=$(date -u -d "$LOOKBACK_DAYS days ago" +%Y-%m-%d)
  PREV_END=$(date -u -d "$LOOKBACK_DAYS days ago" +%Y-%m-%d)
  PREV_START=$(date -u -d "$((LOOKBACK_DAYS*2)) days ago" +%Y-%m-%d)

  echo "Current period: $START to $END" >> "$REPORT_FILE"
  echo "Previous period: $PREV_START to $PREV_END" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  # current
  curr_raw=$(sum_by_service "$START" "$END")
  curr_tot=$(echo "$curr_raw" | awk -F"\t" '{s+=$2}END{printf "%.2f", s}')
  echo "Total cost (current ${LOOKBACK_DAYS}d): $curr_tot" >> "$REPORT_FILE"
  echo "Breakdown by service (top 20):" >> "$REPORT_FILE"
  echo "$curr_raw" | aggregate_period_total | head -n 20 | awk -F"\t" '{printf "%s\t$%s\n", $1, $2}' >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  # previous
  prev_raw=$(sum_by_service "$PREV_START" "$PREV_END")
  prev_tot=$(echo "$prev_raw" | awk -F"\t" '{s+=$2}END{printf "%.2f", s}')
  echo "Total cost (previous ${LOOKBACK_DAYS}d): $prev_tot" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"

  change=$(percent_change "$prev_tot" "$curr_tot")
  echo "Percent change vs previous: ${change}%" >> "$REPORT_FILE"

  # alert on large increase
  if [ "$change" = "inf" ]; then
    send_slack_alert "Cost Alert: Current ${LOOKBACK_DAYS}d cost is $curr_tot USD (previous $prev_tot). Large increase (previous=0)."
  else
    # numeric compare
    if (( $(echo "$change >= $ALERT_PERCENT" | bc -l) )); then
      send_slack_alert "Cost Alert: Cost increased ${change}% over previous ${LOOKBACK_DAYS}d (current=$curr_tot USD)."
    fi
  fi

  log_message "Cost report written to $REPORT_FILE"
}

main "$@"
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
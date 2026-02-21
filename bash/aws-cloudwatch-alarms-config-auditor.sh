#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-cloudwatch-alarms-config-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

log_message() {
  local msg="$1"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${msg}" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  local text="$1"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    jq -n --arg t "$text" '{text:$t}' | curl -s -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  cat > "$REPORT_FILE" <<EOF
AWS CloudWatch Alarms Configuration Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

check_alarm() {
  local alarm_json="$1"
  local name
  name=$(echo "$alarm_json" | jq -r '.AlarmName // "<unknown>"')
  local actions_count
  actions_count=$(echo "$alarm_json" | jq -r '[.AlarmActions[]?] | length')
  local insufficient_eval
  local eval_periods
  eval_periods=$(echo "$alarm_json" | jq -r '.EvaluationPeriods // 0')
  local period
  period=$(echo "$alarm_json" | jq -r '.Period // 0')
  local threshold
  threshold=$(echo "$alarm_json" | jq -r '.Threshold // "<none>"')
  local treat_missing
  treat_missing=$(echo "$alarm_json" | jq -r '.TreatMissingData // "missing"')

  local findings=()
  if [ "$actions_count" -eq 0 ]; then
    findings+=("No AlarmActions configured (no notification/remediation)")
  fi
  if [ "$eval_periods" -lt 1 ]; then
    findings+=("EvaluationPeriods < 1: $eval_periods")
  fi
  if [ "$period" -lt 60 ]; then
    findings+=("Period < 60s: $period")
  fi
  if [ "$threshold" = "<none>" ]; then
    findings+=("No numeric Threshold found")
  fi
  if [ "$treat_missing" = "ignore" ]; then
    findings+=("TreatMissingData is 'ignore' (may hide missing data issues)")
  fi

  if [ ${#findings[@]} -gt 0 ]; then
    echo "Alarm: $name" >> "$REPORT_FILE"
    echo "  Metric: $(echo "$alarm_json" | jq -r '.MetricName // "(composite)"')" >> "$REPORT_FILE"
    for f in "${findings[@]}"; do
      echo "  - $f" >> "$REPORT_FILE"
    done
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting CloudWatch alarms configuration auditor"

  local alarms_json
  alarms_json=$(aws cloudwatch describe-alarms --output json 2>/dev/null || echo '{"MetricAlarms":[]}')
  local alarms
  alarms=$(echo "$alarms_json" | jq -c '.MetricAlarms[]?') || alarms=""
  if [ -z "$alarms" ]; then
    log_message "No CloudWatch metric alarms found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  echo "$alarms" | while read -r a; do
    if check_alarm "$a"; then
      any=1
      log_message "Findings for alarm: $(echo "$a" | jq -r '.AlarmName')"
    fi
  done

  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "CloudWatch alarms auditor found configuration issues. See $REPORT_FILE on host."
  else
    log_message "No configuration issues found for CloudWatch alarms"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"

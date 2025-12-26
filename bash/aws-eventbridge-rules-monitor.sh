#!/bin/bash

################################################################################
# AWS EventBridge Rules Monitor
# Audits EventBridge event buses and rules: lists event buses, rules per bus,
# targets (Lambda, SQS, SNS, Kinesis, etc.), DLQ config, rule state, event
# patterns, retry policies, and CloudWatch metrics (Invocations, Errors,
# ThrottledRules, FailedInvocations, TargetErrors). Includes env thresholds,
# logging, Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/eventbridge-rules-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/eventbridge-rules-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
FAILED_INVOCATIONS_WARN="${FAILED_INVOCATIONS_WARN:-5}"  # failed invocations count
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-2}"         # % errors vs invocations
THROTTLED_RULES_WARN="${THROTTLED_RULES_WARN:-1}"       # throttled rules count
TARGET_ERRORS_WARN="${TARGET_ERRORS_WARN:-5}"           # target errors count
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_EVENT_BUSES=0
CUSTOM_EVENT_BUSES=0
TOTAL_RULES=0
RULES_DISABLED=0
RULES_WITH_DLQ=0
RULES_WITH_ISSUES=0
TOTAL_TARGETS=0
TARGETS_WITH_ISSUES=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="good" ;;
  esac
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "AWS EventBridge Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS EventBridge Rules Monitor"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Failed Invocations Warning: >= ${FAILED_INVOCATIONS_WARN}"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  Throttled Rules Warning: >= ${THROTTLED_RULES_WARN}"
    echo "  Target Errors Warning: >= ${TARGET_ERRORS_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_event_buses() {
  aws_cmd events list-event-buses \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"EventBuses":[]}'
}

list_rules() {
  local event_bus="${1:-default}"
  aws_cmd events list-rules \
    --event-bus-name "${event_bus}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Rules":[]}'
}

describe_rule() {
  local rule_name="$1" event_bus="${2:-default}"
  aws_cmd events describe-rule \
    --name "$rule_name" \
    --event-bus-name "${event_bus}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_targets() {
  local rule_name="$1" event_bus="${2:-default}"
  aws_cmd events list-targets-by-rule \
    --rule "$rule_name" \
    --event-bus-name "${event_bus}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Targets":[]}'
}

get_metrics() {
  local rule_name="$1" metric="$2" stat_type="${3:-Sum}"
  local extra_stats=( )
  if [[ "$stat_type" == "EXTENDED" ]]; then
    extra_stats+=(--extended-statistics p95 p99)
  else
    extra_stats+=(--statistics "$stat_type")
  fi
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Events \
    --metric-name "$metric" \
    --dimensions Name=RuleName,Value="$rule_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    "${extra_stats[@]}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_targets() {
  local rule_name="$1" event_bus="${2:-default}"
  local targets_json
  targets_json=$(list_targets "$rule_name" "$event_bus")
  local target_count
  target_count=$(echo "${targets_json}" | jq -r '.Targets | length')

  {
    echo "    Targets: ${target_count}"
  } >> "${OUTPUT_FILE}"

  if [[ "${target_count}" == "0" ]]; then
    echo "      (no targets)" >> "${OUTPUT_FILE}"
    return
  fi

  TOTAL_TARGETS=$((TOTAL_TARGETS + target_count))

  echo "${targets_json}" | jq -c '.Targets[]' | while read -r target; do
    local target_id arn role_arn dlq_arn retry_policy
    target_id=$(echo "${target}" | jq_safe '.Id')
    arn=$(echo "${target}" | jq_safe '.Arn')
    role_arn=$(echo "${target}" | jq_safe '.RoleArn // ""')
    dlq_arn=$(echo "${target}" | jq_safe '.DeadLetterConfig.Arn // ""')
    retry_policy=$(echo "${target}" | jq -c '.RetryPolicy // {}' 2>/dev/null)

    local target_type
    case "$arn" in
      arn:aws:lambda:*) target_type="Lambda" ;;
      arn:aws:sqs:*) target_type="SQS" ;;
      arn:aws:sns:*) target_type="SNS" ;;
      arn:aws:kinesis:*) target_type="Kinesis" ;;
      arn:aws:states:*) target_type="StepFunctions" ;;
      arn:aws:logs:*) target_type="CloudWatchLogs" ;;
      arn:aws:ec2:*) target_type="EC2" ;;
      *) target_type="Other" ;;
    esac

    {
      echo "      - ${target_id} (${target_type})"
      echo "        ARN: ${arn}"
      [[ -n "${dlq_arn}" ]] && echo "        DLQ: ${dlq_arn}"
      echo "        Retry Policy: ${retry_policy}"
    } >> "${OUTPUT_FILE}"
  done <<< "$(echo "${targets_json}" | jq -c '.Targets[]')"
}

analyze_rule() {
  local rule_json="$1" event_bus="${2:-default}"
  local rule_name state pattern description schedule arn
  rule_name=$(echo "${rule_json}" | jq_safe '.Name')
  state=$(echo "${rule_json}" | jq_safe '.State')
  pattern=$(echo "${rule_json}" | jq -c '.EventPattern // {}' 2>/dev/null)
  description=$(echo "${rule_json}" | jq_safe '.Description // ""')
  schedule=$(echo "${rule_json}" | jq_safe '.ScheduleExpression // ""')
  arn=$(echo "${rule_json}" | jq_safe '.Arn')

  TOTAL_RULES=$((TOTAL_RULES + 1))
  log_message INFO "Analyzing rule: ${rule_name} on bus ${event_bus}"

  [[ "${state}" == "DISABLED" ]] && RULES_DISABLED=$((RULES_DISABLED + 1))

  {
    echo "  Rule: ${rule_name}"
    echo "    ARN: ${arn}"
    echo "    State: ${state}"
    [[ -n "${description}" ]] && echo "    Description: ${description}"
    [[ -n "${schedule}" ]] && echo "    Schedule: ${schedule}"
    [[ "${pattern}" != "{}" ]] && echo "    Pattern: ${pattern}"
  } >> "${OUTPUT_FILE}"

  # CloudWatch Metrics
  local invocations failed_invocations throttled target_errors
  invocations=$(get_metrics "$rule_name" "Invocations" "Sum" | calculate_sum)
  failed_invocations=$(get_metrics "$rule_name" "FailedInvocations" "Sum" | calculate_sum)
  throttled=$(get_metrics "$rule_name" "ThrottledRules" "Sum" | calculate_sum)
  target_errors=$(get_metrics "$rule_name" "TargetErrors" "Sum" | calculate_sum)

  local error_rate="0"
  if (( $(echo "${invocations} > 0" | bc -l 2>/dev/null || echo 0) )); then
    error_rate=$(awk -v f="${failed_invocations}" -v i="${invocations}" 'BEGIN { if (i>0) printf "%.2f", (f*100)/i; else print "0" }')
  fi

  {
    echo "    Invocations (${LOOKBACK_HOURS}h): ${invocations}"
    echo "    Failed Invocations: ${failed_invocations} (${error_rate}%)"
    echo "    Throttled Rules: ${throttled}"
    echo "    Target Errors: ${target_errors}"
  } >> "${OUTPUT_FILE}"

  # Check thresholds
  if (( $(echo "${failed_invocations} >= ${FAILED_INVOCATIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    RULES_WITH_ISSUES=$((RULES_WITH_ISSUES + 1))
    record_issue "EventBridge rule ${rule_name} (bus: ${event_bus}) failed invocations ${failed_invocations} >= ${FAILED_INVOCATIONS_WARN}"
  fi

  if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    RULES_WITH_ISSUES=$((RULES_WITH_ISSUES + 1))
    record_issue "EventBridge rule ${rule_name} (bus: ${event_bus}) error rate ${error_rate}% > ${ERROR_RATE_WARN_PCT}%"
  fi

  if (( $(echo "${throttled} >= ${THROTTLED_RULES_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    RULES_WITH_ISSUES=$((RULES_WITH_ISSUES + 1))
    record_issue "EventBridge rule ${rule_name} (bus: ${event_bus}) throttled ${throttled} >= ${THROTTLED_RULES_WARN}"
  fi

  if (( $(echo "${target_errors} >= ${TARGET_ERRORS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    RULES_WITH_ISSUES=$((RULES_WITH_ISSUES + 1))
    record_issue "EventBridge rule ${rule_name} (bus: ${event_bus}) target errors ${target_errors} >= ${TARGET_ERRORS_WARN}"
  fi

  # Analyze targets
  analyze_targets "$rule_name" "$event_bus"

  echo "" >> "${OUTPUT_FILE}"
}

analyze_event_bus() {
  local bus_json="$1"
  local bus_name bus_arn
  bus_name=$(echo "${bus_json}" | jq_safe '.Name')
  bus_arn=$(echo "${bus_json}" | jq_safe '.Arn')

  TOTAL_EVENT_BUSES=$((TOTAL_EVENT_BUSES + 1))
  [[ "${bus_name}" != "default" ]] && CUSTOM_EVENT_BUSES=$((CUSTOM_EVENT_BUSES + 1))

  log_message INFO "Analyzing event bus: ${bus_name}"

  {
    echo "Event Bus: ${bus_name}"
    echo "  ARN: ${bus_arn}"
  } >> "${OUTPUT_FILE}"

  local rules_json
  rules_json=$(list_rules "$bus_name")
  local rule_count
  rule_count=$(echo "${rules_json}" | jq -r '.Rules | length')

  echo "  Rules: ${rule_count}" >> "${OUTPUT_FILE}"

  if [[ "${rule_count}" == "0" ]]; then
    echo "    (no rules)" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    return
  fi

  while read -r rule; do
    analyze_rule "${rule}" "$bus_name"
  done <<< "$(echo "${rules_json}" | jq -c '.Rules[]')"
}

main() {
  write_header
  local buses_json
  buses_json=$(list_event_buses)
  local bus_count
  bus_count=$(echo "${buses_json}" | jq -r '.EventBuses | length')

  if [[ "${bus_count}" == "0" ]]; then
    log_message WARN "No event buses found in region ${REGION}"
    echo "No event buses found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Event Buses: ${bus_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r bus; do
    analyze_event_bus "${bus}"
  done <<< "$(echo "${buses_json}" | jq -c '.EventBuses[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Event Buses: ${TOTAL_EVENT_BUSES}"
    echo "Custom Event Buses: ${CUSTOM_EVENT_BUSES}"
    echo "Total Rules: ${TOTAL_RULES}"
    echo "Disabled Rules: ${RULES_DISABLED}"
    echo "Rules with Issues: ${RULES_WITH_ISSUES}"
    echo "Total Targets: ${TOTAL_TARGETS}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "EventBridge Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "EventBridge Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

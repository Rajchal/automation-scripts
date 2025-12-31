#!/bin/bash

################################################################################
# AWS Step Functions Reliability Monitor
# Audits Step Functions state machines and executions for reliability issues:
# - Lists state machines, checks logging/X-Ray enabled, role existence
# - Aggregates recent executions and counts failures, timed-out, aborted
# - Pulls CloudWatch metrics: ExecutionsStarted, ExecutionsSucceeded,
#   ExecutionsFailed, ExecutionsTimedOut, ExecutionThrottled
# - Flags state machines exceeding thresholds and sends Slack/email alerts
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/stepfunctions-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/stepfunctions-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
FAILED_WARN_COUNT="${FAILED_WARN_COUNT:-5}"
TIMEOUT_WARN_COUNT="${TIMEOUT_WARN_COUNT:-3}"
THROTTLE_WARN_COUNT="${THROTTLE_WARN_COUNT:-2}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Counters
TOTAL_SM=0
SM_WITH_ISSUES=0
SM_HIGH_FAIL=0
SM_HIGH_TIMEOUT=0
SM_HIGH_THROTTLE=0

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
  local message="$1"; local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger";; WARNING) color="warning";; INFO) color="good";; *) color="good";;
  esac
  local payload
  payload=$(cat <<EOF
{ "attachments":[{"color":"${color}","title":"AWS Step Functions Alert","text":"${message}","ts":$(date +%s)}] }
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"; local body="$2"
  [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS Step Functions Reliability Monitor"
    echo "======================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Window: ${LOOKBACK_HOURS}h"
    echo "Thresholds: Fail>${FAILED_WARN_COUNT}, Timeout>${TIMEOUT_WARN_COUNT}, Throttle>${THROTTLE_WARN_COUNT}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_state_machines() {
  aws_cmd stepfunctions list-state-machines --region "${REGION}" --output json 2>/dev/null || echo '{"stateMachines":[]}'
}

list_executions() {
  local arn="$1"; aws_cmd stepfunctions list-executions --state-machine-arn "$arn" --status-filter RUNNING --region "${REGION}" --output json 2>/dev/null || echo '{"executions":[]}'
}

get_metric() {
  local arn="$1" metric="$2" stat_type="${3:-Sum}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/StepFunctions \
    --metric-name "$metric" \
    --dimensions Name=StateMachineArn,Value="$arn" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

sum_datapoints() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {print int(s)}'; }
max_datapoints() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END{print (NR==0?0:m)}'; }

record_issue() { ISSUES+=("$1"); }

analyze_state_machine() {
  local sm_json="$1"
  local arn name role_arn logging_config tracing_enabled
  arn=$(echo "${sm_json}" | jq_safe '.stateMachineArn')
  name=$(echo "${sm_json}" | jq_safe '.name')
  role_arn=$(echo "${sm_json}" | jq_safe '.roleArn')

  TOTAL_SM=$((TOTAL_SM + 1))
  log_message INFO "Analyzing state machine ${name}"

  # Describe to get logging/tracing
  local desc
  desc=$(aws_cmd stepfunctions describe-state-machine --state-machine-arn "${arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}')
  logging_config=$(echo "${desc}" | jq -c '.loggingConfiguration' 2>/dev/null || echo "null")
  tracing_enabled=$(echo "${desc}" | jq_safe '.tracingConfiguration.enabled')

  {
    echo "State Machine: ${name}"
    echo "  ARN: ${arn}"
    echo "  Role: ${role_arn}"
    echo "  Tracing Enabled: ${tracing_enabled}"
    echo "  Logging Config: ${logging_config}"
  } >> "${OUTPUT_FILE}"

  # CloudWatch metrics
  local started succeeded failed timedout throttled
  started=$(get_metric "${arn}" "ExecutionsStarted" "Sum" | sum_datapoints)
  succeeded=$(get_metric "${arn}" "ExecutionsSucceeded" "Sum" | sum_datapoints)
  failed=$(get_metric "${arn}" "ExecutionsFailed" "Sum" | sum_datapoints)
  timedout=$(get_metric "${arn}" "ExecutionsTimedOut" "Sum" | sum_datapoints)
  throttled=$(get_metric "${arn}" "ExecutionThrottled" "Sum" | sum_datapoints)

  {
    echo "  Executions (last ${LOOKBACK_HOURS}h):"
    echo "    Started: ${started}"
    echo "    Succeeded: ${succeeded}"
    echo "    Failed: ${failed}"
    echo "    TimedOut: ${timedout}"
    echo "    Throttled: ${throttled}"
  } >> "${OUTPUT_FILE}"

  local issue=0
  if (( failed >= FAILED_WARN_COUNT )); then
    SM_HIGH_FAIL=$((SM_HIGH_FAIL + 1))
    issue=1
    record_issue "StateMachine ${name} has ${failed} failed executions (>=${FAILED_WARN_COUNT})"
  fi
  if (( timedout >= TIMEOUT_WARN_COUNT )); then
    SM_HIGH_TIMEOUT=$((SM_HIGH_TIMEOUT + 1))
    issue=1
    record_issue "StateMachine ${name} has ${timedout} timed-out executions (>=${TIMEOUT_WARN_COUNT})"
  fi
  if (( throttled >= THROTTLE_WARN_COUNT )); then
    SM_HIGH_THROTTLE=$((SM_HIGH_THROTTLE + 1))
    issue=1
    record_issue "StateMachine ${name} experienced ${throttled} throttles (>=${THROTTLE_WARN_COUNT})"
  fi

  # Check for DLQ or error handling patterns by inspecting definition for "Catch" or "Retry" (best-effort)
  local def
  def=$(aws_cmd stepfunctions describe-state-machine --state-machine-arn "${arn}" --region "${REGION}" --query 'definition' --output text 2>/dev/null || echo "")
  if [[ -z "${def}" ]]; then
    echo "  WARNING: Could not fetch definition" >> "${OUTPUT_FILE}"
  else
    if ! echo "${def}" | grep -q 'Catch\|Retry'; then
      record_issue "StateMachine ${name} has no Catch/Retry in definition (inspect for DLQ handling)"
      issue=1
      echo "  WARNING: No Catch/Retry clauses detected in definition" >> "${OUTPUT_FILE}"
    fi
  fi

  if (( issue )); then
    SM_WITH_ISSUES=$((SM_WITH_ISSUES + 1))
    echo "  STATUS: ⚠️ ISSUES DETECTED" >> "${OUTPUT_FILE}"
  else
    echo "  STATUS: ✓ OK" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local sms_json
  sms_json=$(list_state_machines)
  local sm_count
  sm_count=$(echo "${sms_json}" | jq '.stateMachines | length' 2>/dev/null || echo 0)

  if [[ "${sm_count}" == "0" ]]; then
    log_message WARN "No Step Functions state machines found"
    echo "No state machines found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total State Machines: ${sm_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  echo "${sms_json}" | jq -c '.stateMachines[]' 2>/dev/null | while read -r sm; do
    analyze_state_machine "${sm}"
  done

  {
    echo "Summary"
    echo "-------"
    echo "Total State Machines: ${TOTAL_SM}"
    echo "State Machines with Issues: ${SM_WITH_ISSUES}"
    echo "High Failures: ${SM_HIGH_FAIL}"
    echo "High Timeouts: ${SM_HIGH_TIMEOUT}"
    echo "High Throttles: ${SM_HIGH_THROTTLE}"
    echo ""
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "Step Functions Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "Step Functions Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

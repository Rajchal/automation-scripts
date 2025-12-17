#!/bin/bash

################################################################################
# AWS Lambda Performance Monitor
# Monitors Lambda functions for performance metrics, concurrency, errors, and timeouts
# Detects high error rates, duration issues, and concurrent execution bottlenecks
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/lambda-monitor-$(date +%s).txt"
LOG_FILE="/var/log/lambda-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-5}"      # % of invocations
DURATION_WARN_MS="${DURATION_WARN_MS:-5000}"           # milliseconds
THROTTLE_THRESHOLD="${THROTTLE_THRESHOLD:-1}"           # count
MAX_FUNCTIONS="${MAX_FUNCTIONS:-100}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || true; }
start_window() { date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%SZ; }
now_window() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# API wrappers
list_functions() {
  aws lambda list-functions \
    --region "${REGION}" \
    --query "Functions[*].[FunctionName,FunctionArn,Runtime,LastModified]" \
    --output text 2>/dev/null | head -${MAX_FUNCTIONS} || true
}

get_function_config() {
  local func="$1"
  aws lambda get-function-configuration \
    --function-name "${func}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metrics() {
  local func="$1"; local metric="$2"; local stat="${3:-Sum}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name "${metric}" \
    --dimensions Name=FunctionName,Value="${func}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].'${stat} \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{if(n>0) printf("%.0f", sum); else print "0"}'
}

write_header() {
  {
    echo "AWS Lambda Performance Monitoring Report"
    echo "========================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "Error Rate Threshold: ${ERROR_RATE_THRESHOLD}%"
    echo "Duration Warning: ${DURATION_WARN_MS}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_functions_overview() {
  log_message INFO "Listing Lambda functions"
  {
    echo "=== FUNCTIONS OVERVIEW ==="
  } >> "${OUTPUT_FILE}"

  list_functions | while IFS=$'\t' read -r name arn runtime modified; do
    [[ -z "${name}" ]] && continue
    {
      echo "Function: ${name}"
      echo "  ARN: ${arn}"
      echo "  Runtime: ${runtime}"
      echo "  Modified: ${modified}"
    } >> "${OUTPUT_FILE}"
  done | head -50

  echo "" >> "${OUTPUT_FILE}"
}

monitor_function_metrics() {
  log_message INFO "Collecting function metrics"
  {
    echo "=== FUNCTION METRICS & HEALTH ==="
  } >> "${OUTPUT_FILE}"

  local high_error_count=0 high_duration_count=0 throttle_count=0

  list_functions | while IFS=$'\t' read -r name arn runtime modified; do
    [[ -z "${name}" ]] && continue

    # Get config
    local config timeout memory concurrency
    config=$(get_function_config "${name}")
    timeout=$(echo "${config}" | jq_safe '.Timeout')
    memory=$(echo "${config}" | jq_safe '.MemorySize')
    concurrency=$(echo "${config}" | jq_safe '.ReservedConcurrentExecutions')

    # CloudWatch metrics
    local invocations errors duration throttles concurrent_exec
    invocations=$(get_metrics "${name}" "Invocations" "Sum" || echo "0")
    errors=$(get_metrics "${name}" "Errors" "Sum" || echo "0")
    duration=$(get_metrics "${name}" "Duration" "Average" || echo "0")
    throttles=$(get_metrics "${name}" "Throttles" "Sum" || echo "0")
    concurrent_exec=$(get_metrics "${name}" "ConcurrentExecutions" "Maximum" || echo "0")

    # Calculate error rate
    local error_rate=0
    if (( invocations > 0 )); then
      error_rate=$(( errors * 100 / invocations ))
    fi

    {
      echo "Function: ${name}"
      echo "  Memory: ${memory}MB  Timeout: ${timeout}s"
      [[ -n "${concurrency}" && "${concurrency}" != "null" ]] && echo "  Reserved Concurrency: ${concurrency}"
      echo "  Invocations: ${invocations}"
      echo "  Errors: ${errors} (${error_rate}%)"
      echo "  Avg Duration: ${duration}ms"
      echo "  Throttles: ${throttles}"
      echo "  Max Concurrent Exec: ${concurrent_exec}"
    } >> "${OUTPUT_FILE}"

    # Flags
    if (( error_rate >= ERROR_RATE_THRESHOLD )); then
      ((high_error_count++))
      echo "  WARNING: High error rate (${error_rate}% >= ${ERROR_RATE_THRESHOLD}%)" >> "${OUTPUT_FILE}"
    fi
    if (( duration >= DURATION_WARN_MS )); then
      ((high_duration_count++))
      echo "  WARNING: High avg duration (${duration}ms >= ${DURATION_WARN_MS}ms)" >> "${OUTPUT_FILE}"
    fi
    if (( throttles >= THROTTLE_THRESHOLD )); then
      ((throttle_count++))
      echo "  WARNING: Function throttled (${throttles} times)" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Summary:"
    echo "  High Error Rate: ${high_error_count}"
    echo "  High Duration: ${high_duration_count}"
    echo "  Throttled: ${throttle_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_concurrent_limits() {
  log_message INFO "Checking concurrency limits and saturation"
  {
    echo "=== CONCURRENCY ANALYSIS ==="
  } >> "${OUTPUT_FILE}"

  list_functions | while IFS=$'\t' read -r name arn runtime modified; do
    [[ -z "${name}" ]] && continue

    local config concurrency concurrent_exec
    config=$(get_function_config "${name}")
    concurrency=$(echo "${config}" | jq_safe '.ReservedConcurrentExecutions')
    concurrent_exec=$(get_metrics "${name}" "ConcurrentExecutions" "Maximum" || echo "0")

    if [[ -n "${concurrency}" && "${concurrency}" != "null" ]]; then
      {
        echo "Function: ${name}"
        echo "  Reserved Concurrency: ${concurrency}"
        echo "  Max Concurrent Exec: ${concurrent_exec}"
      } >> "${OUTPUT_FILE}"

      # Check if approaching limit
      if (( concurrent_exec > 0 )); then
        local utilization=$(( concurrent_exec * 100 / concurrency ))
        echo "  Utilization: ${utilization}%" >> "${OUTPUT_FILE}"
        if (( utilization >= 80 )); then
          echo "  WARNING: Concurrency utilization high (${utilization}%)" >> "${OUTPUT_FILE}"
        fi
      fi
      echo "" >> "${OUTPUT_FILE}"
    fi
  done
}

report_dead_letter_queues() {
  log_message INFO "Checking Lambda DLQ and async configs"
  {
    echo "=== ASYNC EXECUTION & DLQ CONFIG ==="
  } >> "${OUTPUT_FILE}"

  list_functions | while IFS=$'\t' read -r name arn runtime modified; do
    [[ -z "${name}" ]] && continue

    local config dlq
    config=$(get_function_config "${name}")
    dlq=$(echo "${config}" | jq -r '.DeadLetterConfig.TargetArn // "NONE"' 2>/dev/null || echo "NONE")

    if [[ "${dlq}" != "NONE" ]]; then
      {
        echo "Function: ${name}"
        echo "  Dead Letter Queue: ${dlq}"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done
}

send_slack_alert() {
  local func_count="$1"; local error_funcs="$2"; local throttled="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Lambda Performance Monitor",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Functions Monitored", "value": "${func_count}", "short": true},
        {"title": "High Error Rate", "value": "${error_funcs}", "short": true},
        {"title": "Throttled", "value": "${throttled}", "short": true},
        {"title": "Error Threshold", "value": "${ERROR_RATE_THRESHOLD}%", "short": true},
        {"title": "Duration Threshold", "value": "${DURATION_WARN_MS}ms", "short": true},
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
  log_message INFO "Starting AWS Lambda performance monitoring"
  write_header
  report_functions_overview
  monitor_function_metrics
  check_concurrent_limits
  report_dead_letter_queues
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local func_count error_count throttle_count
  func_count=$(aws lambda list-functions --region "${REGION}" --query 'length(Functions)' --output text 2>/dev/null || echo 0)
  error_count=$(grep -c "High error rate" "${OUTPUT_FILE}" || echo 0)
  throttle_count=$(grep -c "WARNING: Function throttled" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${func_count}" "${error_count}" "${throttle_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

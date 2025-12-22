#!/bin/bash

################################################################################
# AWS Step Functions Orchestration Monitor
# Monitors state machines, tracks execution success/failure rates, identifies
# stuck executions, analyzes duration, provides optimization recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/stepfunctions-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/stepfunctions-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
FAILURE_RATE_WARN="${FAILURE_RATE_WARN:-5}"           # % failures
STUCK_EXECUTION_HOURS="${STUCK_EXECUTION_HOURS:-24}" # hours running
EXECUTION_TIMEOUT_WARN="${EXECUTION_TIMEOUT_WARN:-3600}" # seconds
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_STATE_MACHINES=0
ACTIVE_EXECUTIONS=0
SUCCEEDED_EXECUTIONS=0
FAILED_EXECUTIONS=0
TIMED_OUT_EXECUTIONS=0
STUCK_EXECUTIONS=0

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

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
      "title": "Step Functions Alert",
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
    echo "AWS Step Functions Orchestration Monitor"
    echo "========================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_DAYS} days"
    echo ""
    echo "Thresholds:"
    echo "  Failure Rate Warning: ${FAILURE_RATE_WARN}%"
    echo "  Stuck Execution: ${STUCK_EXECUTION_HOURS}h"
    echo "  Timeout Warning: ${EXECUTION_TIMEOUT_WARN}s"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_state_machines() {
  aws stepfunctions list-state-machines \
    --region "${REGION}" \
    --max-results 100 \
    --output json 2>/dev/null || echo '{"stateMachines":[]}'
}

describe_state_machine() {
  local arn="$1"
  aws stepfunctions describe-state-machine \
    --state-machine-arn "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_executions() {
  local sm_arn="$1"
  local status="${2:-}"
  local max_results="${3:-100}"
  
  if [[ -n "${status}" ]]; then
    aws stepfunctions list-executions \
      --state-machine-arn "${sm_arn}" \
      --status-filter "${status}" \
      --max-results ${max_results} \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{"executions":[]}'
  else
    aws stepfunctions list-executions \
      --state-machine-arn "${sm_arn}" \
      --max-results ${max_results} \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{"executions":[]}'
  fi
}

describe_execution() {
  local exec_arn="$1"
  aws stepfunctions describe-execution \
    --execution-arn "${exec_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_execution_history() {
  local exec_arn="$1"
  aws stepfunctions get-execution-history \
    --execution-arn "${exec_arn}" \
    --max-results 50 \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"events":[]}'
}

get_sfn_metrics() {
  local sm_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/States \
    --metric-name "${metric_name}" \
    --dimensions Name=StateMachineArn,Value="${sm_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() {
  jq -r '.Datapoints[].Sum' 2>/dev/null | \
    awk '{s+=$1} END {printf "%.0f", s}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

monitor_state_machines() {
  log_message INFO "Starting Step Functions monitoring"
  
  {
    echo "=== STATE MACHINE INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local sms_json
  sms_json=$(list_state_machines)
  
  local sm_count
  sm_count=$(echo "${sms_json}" | jq '.stateMachines | length' 2>/dev/null || echo "0")
  
  TOTAL_STATE_MACHINES=${sm_count}
  
  if [[ ${sm_count} -eq 0 ]]; then
    log_message WARN "No state machines found in region ${REGION}"
    {
      echo "Status: No state machines configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total State Machines: ${sm_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local state_machines
  state_machines=$(echo "${sms_json}" | jq -c '.stateMachines[]' 2>/dev/null)
  
  while IFS= read -r sm; do
    [[ -z "${sm}" ]] && continue
    
    local sm_name sm_arn created_date sm_type
    sm_name=$(echo "${sm}" | jq_safe '.name')
    sm_arn=$(echo "${sm}" | jq_safe '.stateMachineArn')
    created_date=$(echo "${sm}" | jq_safe '.creationDate')
    sm_type=$(echo "${sm}" | jq_safe '.type')
    
    log_message INFO "Analyzing state machine: ${sm_name}"
    
    {
      echo "State Machine: ${sm_name}"
      echo "ARN: ${sm_arn}"
      echo "Type: ${sm_type}"
      echo "Created: ${created_date}"
    } >> "${OUTPUT_FILE}"
    
    # Get detailed info
    local sm_detail
    sm_detail=$(describe_state_machine "${sm_arn}")
    
    local status
    status=$(echo "${sm_detail}" | jq_safe '.status')
    
    {
      echo "Status: ${status}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze executions
    analyze_executions "${sm_name}" "${sm_arn}"
    
    # Get CloudWatch metrics
    analyze_metrics "${sm_name}" "${sm_arn}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${state_machines}"
}

analyze_executions() {
  local sm_name="$1"
  local sm_arn="$2"
  
  {
    echo "Execution Analysis:"
  } >> "${OUTPUT_FILE}"
  
  # Get running executions
  local running_json
  running_json=$(list_executions "${sm_arn}" "RUNNING" 50)
  
  local running_count
  running_count=$(echo "${running_json}" | jq '.executions | length' 2>/dev/null || echo "0")
  
  ACTIVE_EXECUTIONS=$((ACTIVE_EXECUTIONS + running_count))
  
  {
    echo "  Running Executions: ${running_count}"
  } >> "${OUTPUT_FILE}"
  
  # Check for stuck executions
  if [[ ${running_count} -gt 0 ]]; then
    local running_execs
    running_execs=$(echo "${running_json}" | jq -c '.executions[]' 2>/dev/null)
    
    while IFS= read -r exec; do
      [[ -z "${exec}" ]] && continue
      
      local exec_arn exec_name start_date
      exec_arn=$(echo "${exec}" | jq_safe '.executionArn')
      exec_name=$(echo "${exec}" | jq_safe '.name')
      start_date=$(echo "${exec}" | jq_safe '.startDate')
      
      # Calculate running time
      local start_epoch current_epoch running_hours
      start_epoch=$(date -d "${start_date}" +%s 2>/dev/null || echo "0")
      current_epoch=$(date +%s)
      running_hours=$(( (current_epoch - start_epoch) / 3600 ))
      
      if [[ ${running_hours} -gt ${STUCK_EXECUTION_HOURS} ]]; then
        ((STUCK_EXECUTIONS++))
        {
          echo ""
          printf "  %b⚠️  Stuck Execution Detected:%b\n" "${RED}" "${NC}"
          echo "    Execution: ${exec_name}"
          echo "    Running Time: ${running_hours} hours"
          echo "    Started: ${start_date}"
        } >> "${OUTPUT_FILE}"
        log_message WARN "State machine ${sm_name} has stuck execution: ${exec_name} (${running_hours}h)"
      fi
      
    done <<< "${running_execs}"
  fi
  
  # Get recent succeeded executions
  local succeeded_json
  succeeded_json=$(list_executions "${sm_arn}" "SUCCEEDED" 20)
  
  local succeeded_count
  succeeded_count=$(echo "${succeeded_json}" | jq '.executions | length' 2>/dev/null || echo "0")
  
  SUCCEEDED_EXECUTIONS=$((SUCCEEDED_EXECUTIONS + succeeded_count))
  
  # Get recent failed executions
  local failed_json
  failed_json=$(list_executions "${sm_arn}" "FAILED" 20)
  
  local failed_count
  failed_count=$(echo "${failed_json}" | jq '.executions | length' 2>/dev/null || echo "0")
  
  FAILED_EXECUTIONS=$((FAILED_EXECUTIONS + failed_count))
  
  # Get timed out executions
  local timedout_json
  timedout_json=$(list_executions "${sm_arn}" "TIMED_OUT" 20)
  
  local timedout_count
  timedout_count=$(echo "${timedout_json}" | jq '.executions | length' 2>/dev/null || echo "0")
  
  TIMED_OUT_EXECUTIONS=$((TIMED_OUT_EXECUTIONS + timedout_count))
  
  {
    echo "  Recent Succeeded: ${succeeded_count}"
    echo "  Recent Failed: ${failed_count}"
    echo "  Recent Timed Out: ${timedout_count}"
  } >> "${OUTPUT_FILE}"
  
  # Calculate failure rate
  local total_recent
  total_recent=$((succeeded_count + failed_count + timedout_count))
  
  if [[ ${total_recent} -gt 0 ]]; then
    local failure_rate
    failure_rate=$(echo "scale=2; (${failed_count} + ${timedout_count}) * 100 / ${total_recent}" | bc -l)
    
    {
      echo "  Failure Rate: ${failure_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${failure_rate} > ${FAILURE_RATE_WARN}" | bc -l) )); then
      {
        printf "  %b⚠️  High failure rate detected%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "State machine ${sm_name} has high failure rate: ${failure_rate}%"
    else
      {
        printf "  %b✓ Failure rate within acceptable range%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  # Analyze recent failures
  if [[ ${failed_count} -gt 0 ]]; then
    {
      echo ""
      echo "  Recent Failure Details:"
    } >> "${OUTPUT_FILE}"
    
    local failed_execs
    failed_execs=$(echo "${failed_json}" | jq -c '.executions[] | select(.status=="FAILED")' 2>/dev/null | head -5)
    
    local failure_num=0
    while IFS= read -r exec; do
      [[ -z "${exec}" ]] && continue
      ((failure_num++))
      [[ ${failure_num} -gt 3 ]] && break
      
      local exec_arn exec_name stop_date
      exec_arn=$(echo "${exec}" | jq_safe '.executionArn')
      exec_name=$(echo "${exec}" | jq_safe '.name')
      stop_date=$(echo "${exec}" | jq_safe '.stopDate')
      
      # Get execution details for error
      local exec_detail
      exec_detail=$(describe_execution "${exec_arn}")
      
      local error cause
      error=$(echo "${exec_detail}" | jq_safe '.error // "Unknown"')
      cause=$(echo "${exec_detail}" | jq_safe '.cause // "No cause provided"' | head -c 100)
      
      {
        echo "    - Execution: ${exec_name}"
        echo "      Stopped: ${stop_date}"
        echo "      Error: ${error}"
        echo "      Cause: ${cause}..."
      } >> "${OUTPUT_FILE}"
      
    done <<< "${failed_execs}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_metrics() {
  local sm_name="$1"
  local sm_arn="$2"
  
  {
    echo "Performance Metrics (${LOOKBACK_DAYS}d):"
  } >> "${OUTPUT_FILE}"
  
  # Get execution metrics
  local started_json succeeded_json failed_json duration_json
  started_json=$(get_sfn_metrics "${sm_arn}" "ExecutionStarted")
  succeeded_json=$(get_sfn_metrics "${sm_arn}" "ExecutionSucceeded")
  failed_json=$(get_sfn_metrics "${sm_arn}" "ExecutionFailed")
  duration_json=$(get_sfn_metrics "${sm_arn}" "ExecutionTime")
  
  local started_count succeeded_count failed_count avg_duration
  started_count=$(echo "${started_json}" | calculate_sum)
  succeeded_count=$(echo "${succeeded_json}" | calculate_sum)
  failed_count=$(echo "${failed_json}" | calculate_sum)
  avg_duration=$(echo "${duration_json}" | calculate_avg)
  
  # Convert duration from ms to seconds
  local avg_duration_sec
  avg_duration_sec=$(echo "scale=2; ${avg_duration} / 1000" | bc -l 2>/dev/null || echo "0")
  
  {
    echo "  Total Started: ${started_count}"
    echo "  Total Succeeded: ${succeeded_count}"
    echo "  Total Failed: ${failed_count}"
    echo "  Average Duration: ${avg_duration_sec}s"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_duration_sec} > ${EXECUTION_TIMEOUT_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    {
      printf "  %b⚠️  Long execution duration detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Get throttled executions
  local throttled_json
  throttled_json=$(get_sfn_metrics "${sm_arn}" "ExecutionThrottled")
  
  local throttled_count
  throttled_count=$(echo "${throttled_json}" | calculate_sum)
  
  if [[ ${throttled_count} -gt 0 ]]; then
    {
      echo "  Throttled Executions: ${throttled_count}"
      printf "  %b⚠️  Throttling detected - consider increasing limits%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "State machine ${sm_name} has throttled executions: ${throttled_count}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== STEP FUNCTIONS SUMMARY ==="
    echo ""
    printf "Total State Machines: %d\n" "${TOTAL_STATE_MACHINES}"
    echo ""
    echo "Execution Status:"
    printf "  Currently Running: %d\n" "${ACTIVE_EXECUTIONS}"
    printf "  Recent Succeeded: %d\n" "${SUCCEEDED_EXECUTIONS}"
    printf "  Recent Failed: %d\n" "${FAILED_EXECUTIONS}"
    printf "  Recent Timed Out: %d\n" "${TIMED_OUT_EXECUTIONS}"
    echo ""
    
    if [[ ${STUCK_EXECUTIONS} -gt 0 ]]; then
      printf "%b⚠️  Stuck Executions: %d%b\n" "${RED}" "${STUCK_EXECUTIONS}" "${NC}"
    fi
    
    echo ""
    
    if [[ ${STUCK_EXECUTIONS} -gt 0 ]] || [[ ${FAILED_EXECUTIONS} -gt ${FAILURE_RATE_WARN} ]]; then
      printf "%b[WARNING] Step Functions issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All state machines operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${STUCK_EXECUTIONS} -gt 0 ]]; then
      echo "Stuck Execution Remediation:"
      echo "  • Review state machine timeout configuration"
      echo "  • Check for infinite loops in Choice states"
      echo "  • Implement heartbeat timeouts in Task states"
      echo "  • Use ExecutionTimedOut error handling"
      echo "  • Consider implementing circuit breaker patterns"
      echo ""
    fi
    
    if [[ ${FAILED_EXECUTIONS} -gt 0 ]]; then
      echo "Failure Reduction Strategies:"
      echo "  • Implement Retry policies with exponential backoff"
      echo "  • Add Catch blocks for error handling"
      echo "  • Use State.ALL to catch all errors"
      echo "  • Validate input/output with Parameters and ResultPath"
      echo "  • Implement dead letter queues for failed executions"
      echo "  • Enable CloudWatch Logs for debugging"
      echo ""
    fi
    
    echo "Performance Optimization:"
    echo "  • Use Parallel states for independent tasks"
    echo "  • Implement Map state for batch processing"
    echo "  • Keep state machine definitions under 1MB"
    echo "  • Minimize data passed between states (use S3 for large payloads)"
    echo "  • Use Express Workflows for high-volume, short-duration workloads"
    echo "  • Standard Workflows for long-running, auditable processes"
    echo "  • Optimize Lambda functions called by state machines"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • Express Workflows: Better for >100K executions/day"
    echo "  • Standard Workflows: Better for long-running, low-volume"
    echo "  • Use Wait state instead of polling"
    echo "  • Implement efficient retry strategies (max 3 attempts)"
    echo "  • Clean up old execution history regularly"
    echo "  • Monitor state transition counts for cost tracking"
    echo ""
    
    echo "Monitoring & Observability:"
    echo "  • Enable CloudWatch Logs at state machine level"
    echo "  • Set up CloudWatch alarms for ExecutionFailed metric"
    echo "  • Track execution duration trends"
    echo "  • Monitor throttling events"
    echo "  • Use AWS X-Ray for distributed tracing"
    echo "  • Implement custom CloudWatch metrics via Lambda"
    echo "  • Tag state machines for cost allocation"
    echo ""
    
    echo "Error Handling Best Practices:"
    echo "  • Define Retry for transient failures (network, throttling)"
    echo "  • Define Catch for business logic errors"
    echo "  • Use $.errorType and $.cause for error analysis"
    echo "  • Implement compensating transactions for rollbacks"
    echo "  • Send notifications via SNS on critical failures"
    echo "  • Log detailed error context to CloudWatch"
    echo ""
    
    echo "Security Best Practices:"
    echo "  • Use IAM roles with least-privilege permissions"
    echo "  • Encrypt sensitive data in state machine inputs"
    echo "  • Use Secrets Manager for credentials"
    echo "  • Enable CloudTrail logging for audit trail"
    echo "  • Implement VPC endpoints for private connectivity"
    echo "  • Validate and sanitize all inputs"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Step Functions Monitor Started ==="
  
  write_header
  monitor_state_machines
  generate_summary
  optimization_recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Step Functions Documentation:"
    echo "  https://docs.aws.amazon.com/step-functions/"
    echo ""
    echo "View State Machine in Console:"
    echo "  aws stepfunctions describe-state-machine --state-machine-arn <arn>"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Step Functions Monitor Completed ==="
  
  # Send alerts
  if [[ ${STUCK_EXECUTIONS} -gt 0 ]]; then
    send_slack_alert "🚨 ${STUCK_EXECUTIONS} stuck Step Functions execution(s) detected" "CRITICAL"
    send_email_alert "Step Functions Alert: Stuck Executions" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${FAILED_EXECUTIONS} -gt ${FAILURE_RATE_WARN} ]]; then
    send_slack_alert "⚠️ High Step Functions failure rate: ${FAILED_EXECUTIONS} recent failures" "WARNING"
  fi
}

main "$@"

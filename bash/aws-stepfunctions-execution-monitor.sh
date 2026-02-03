#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-stepfunctions-execution-monitor.log"
REPORT_FILE="/tmp/stepfunctions-execution-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_EXECUTIONS="${SFN_MAX_EXECUTIONS:-50}"
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
  echo "Step Functions Execution Monitor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Max executions per state machine: $MAX_EXECUTIONS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  state_machines=$(aws stepfunctions list-state-machines --region "$REGION" --output json 2>/dev/null || echo '{"stateMachines":[]}')
  sm_arns=$(echo "$state_machines" | jq -r '.stateMachines[]?.stateMachineArn')

  if [ -z "$sm_arns" ]; then
    echo "No Step Functions state machines found." >> "$REPORT_FILE"
    log_message "No Step Functions state machines in region $REGION"
    exit 0
  fi

  total_machines=0
  total_failed=0
  total_timed_out=0

  for arn in $sm_arns; do
    total_machines=$((total_machines+1))
    name=$(echo "$state_machines" | jq -r --arg a "$arn" '.stateMachines[] | select(.stateMachineArn==$a) | .name')
    
    echo "State Machine: $name" >> "$REPORT_FILE"
    echo "  ARN: $arn" >> "$REPORT_FILE"

    # Check recent executions with FAILED status
    failed_execs=$(aws stepfunctions list-executions --state-machine-arn "$arn" --status-filter FAILED --max-results "$MAX_EXECUTIONS" --region "$REGION" --output json 2>/dev/null || echo '{"executions":[]}')
    failed_count=$(echo "$failed_execs" | jq '.executions | length')

    # Check recent executions with TIMED_OUT status
    timed_out_execs=$(aws stepfunctions list-executions --state-machine-arn "$arn" --status-filter TIMED_OUT --max-results "$MAX_EXECUTIONS" --region "$REGION" --output json 2>/dev/null || echo '{"executions":[]}')
    timed_out_count=$(echo "$timed_out_execs" | jq '.executions | length')

    # Check recent executions with ABORTED status
    aborted_execs=$(aws stepfunctions list-executions --state-machine-arn "$arn" --status-filter ABORTED --max-results "$MAX_EXECUTIONS" --region "$REGION" --output json 2>/dev/null || echo '{"executions":[]}')
    aborted_count=$(echo "$aborted_execs" | jq '.executions | length')

    echo "  Recent failed executions: $failed_count" >> "$REPORT_FILE"
    echo "  Recent timed out executions: $timed_out_count" >> "$REPORT_FILE"
    echo "  Recent aborted executions: $aborted_count" >> "$REPORT_FILE"

    if [ "$failed_count" -gt 0 ]; then
      total_failed=$((total_failed + failed_count))
      echo "$failed_execs" | jq -c '.executions[]?' | while read -r exec; do
        exec_name=$(echo "$exec" | jq -r '.name')
        exec_arn=$(echo "$exec" | jq -r '.executionArn')
        started=$(echo "$exec" | jq -r '.startDate // "<unknown>"')
        stopped=$(echo "$exec" | jq -r '.stopDate // "<unknown>"')
        echo "    FAILED: $exec_name started=$started stopped=$stopped" >> "$REPORT_FILE"
        send_slack_alert "Step Functions Alert: FAILED execution $exec_name in state machine $name (started=$started stopped=$stopped)"
      done
    fi

    if [ "$timed_out_count" -gt 0 ]; then
      total_timed_out=$((total_timed_out + timed_out_count))
      echo "$timed_out_execs" | jq -c '.executions[]?' | while read -r exec; do
        exec_name=$(echo "$exec" | jq -r '.name')
        started=$(echo "$exec" | jq -r '.startDate // "<unknown>"')
        stopped=$(echo "$exec" | jq -r '.stopDate // "<unknown>"')
        echo "    TIMED_OUT: $exec_name started=$started stopped=$stopped" >> "$REPORT_FILE"
        send_slack_alert "Step Functions Alert: TIMED_OUT execution $exec_name in state machine $name (started=$started stopped=$stopped)"
      done
    fi

    if [ "$aborted_count" -gt 0 ]; then
      echo "$aborted_execs" | jq -c '.executions[]?' | while read -r exec; do
        exec_name=$(echo "$exec" | jq -r '.name')
        started=$(echo "$exec" | jq -r '.startDate // "<unknown>"')
        stopped=$(echo "$exec" | jq -r '.stopDate // "<unknown>"')
        echo "    ABORTED: $exec_name started=$started stopped=$stopped" >> "$REPORT_FILE"
        send_slack_alert "Step Functions Alert: ABORTED execution $exec_name in state machine $name (started=$started stopped=$stopped)"
      done
    fi

    echo "" >> "$REPORT_FILE"
  done

  echo "Summary: state_machines=$total_machines, failed_executions=$total_failed, timed_out_executions=$total_timed_out" >> "$REPORT_FILE"
  log_message "Step Functions report written to $REPORT_FILE (state_machines=$total_machines, failed=$total_failed, timed_out=$total_timed_out)"
}

main "$@"

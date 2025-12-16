#!/bin/bash

################################################################################
# AWS DataSync Monitor
# Monitors DataSync tasks, executions, and locations
# Detects failed/stuck executions and summarizes throughput & progress
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/datasync-monitor-$(date +%s).txt"
LOG_FILE="/var/log/datasync-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
STUCK_MINUTES="${STUCK_MINUTES:-60}"
FAILED_THRESHOLD="${FAILED_THRESHOLD:-1}"
MAX_EXECUTIONS="${MAX_EXECUTIONS:-25}"

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
minutes_to_seconds() { echo $(( $1 * 60 )); }
start_window_iso() { date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%SZ; }

# APIs
list_tasks() {
  aws datasync list-tasks --region "${REGION}" \
    --query 'Tasks[*].[TaskArn,Name,Status]' --output text 2>/dev/null || true
}

describe_task() {
  local task_arn="$1"
  aws datasync describe-task --task-arn "${task_arn}" --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_task_executions() {
  local task_arn="$1"
  aws datasync list-task-executions --task-arn "${task_arn}" --region "${REGION}" \
    --query 'TaskExecutions[*].TaskExecutionArn' --output text 2>/dev/null | head -${MAX_EXECUTIONS} || true
}

describe_task_execution() {
  local exec_arn="$1"
  aws datasync describe-task-execution --task-execution-arn "${exec_arn}" \
    --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_locations() {
  aws datasync list-locations --region "${REGION}" \
    --query 'Locations[*].[LocationArn,LocationUri,CreationTime]' --output text 2>/dev/null || true
}

# Sections
write_header() {
  {
    echo "AWS DataSync Monitoring Report"
    echo "==============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "Stuck Threshold: ${STUCK_MINUTES} minutes"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_locations() {
  log_message INFO "Listing DataSync locations"
  {
    echo "=== LOCATIONS ==="
  } >> "${OUTPUT_FILE}"
  list_locations | while IFS=$'\t' read -r arn uri created; do
    [[ -z "${arn}" ]] && continue
    echo "Location: ${arn}" >> "${OUTPUT_FILE}"
    echo "  URI: ${uri}" >> "${OUTPUT_FILE}"
    echo "  Created: ${created}" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
  done
}

report_tasks_overview() {
  log_message INFO "Fetching tasks overview"
  {
    echo "=== TASKS OVERVIEW ==="
  } >> "${OUTPUT_FILE}"

  list_tasks | while IFS=$'\t' read -r task_arn name status; do
    [[ -z "${task_arn}" ]] && continue
    echo "Task: ${name}" >> "${OUTPUT_FILE}"
    echo "  ARN: ${task_arn}" >> "${OUTPUT_FILE}"
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"

    # Enrich with source/destination URIs
    local tjson src dest cw_logs
    tjson=$(describe_task "${task_arn}")
    src=$(echo "${tjson}" | jq_safe '.SourceLocationArn')
    dest=$(echo "${tjson}" | jq_safe '.DestinationLocationArn')
    cw_logs=$(echo "${tjson}" | jq_safe '.CloudWatchLogGroupArn')

    # Resolve URIs for locations if available
    local src_uri dest_uri
    src_uri=$(aws datasync describe-location --location-arn "${src}" --region "${REGION}" 2>/dev/null \
      | jq -r '.LocationUri // .LocationArn // ""' || true)
    dest_uri=$(aws datasync describe-location --location-arn "${dest}" --region "${REGION}" 2>/dev/null \
      | jq -r '.LocationUri // .LocationArn // ""' || true)

    echo "  Source: ${src_uri:-${src}}" >> "${OUTPUT_FILE}"
    echo "  Destination: ${dest_uri:-${dest}}" >> "${OUTPUT_FILE}"
    [[ -n "${cw_logs}" && "${cw_logs}" != "null" ]] && echo "  CW Logs: ${cw_logs}" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
  done
}

monitor_task_executions() {
  log_message INFO "Analyzing task executions"
  {
    echo "=== TASK EXECUTIONS ==="
  } >> "${OUTPUT_FILE}"

  local stuck_threshold
  stuck_threshold=$(minutes_to_seconds ${STUCK_MINUTES})

  local total_failed=0 total_stuck=0

  list_tasks | while IFS=$'\t' read -r task_arn name _; do
    [[ -z "${task_arn}" ]] && continue

    echo "Task: ${name}" >> "${OUTPUT_FILE}"

    local exec_arns
    exec_arns=$(list_task_executions "${task_arn}")

    if [[ -z "${exec_arns}" ]]; then
      echo "  No recent executions" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    local failed_for_task=0

    for e in ${exec_arns}; do
      local ex desc status start end bytes est files xferred verified skipped err
      desc=$(describe_task_execution "${e}")
      status=$(echo "${desc}" | jq_safe '.Status')
      start=$(echo "${desc}" | jq_safe '.StartTime')
      end=$(echo "${desc}" | jq_safe '.EndTime')
      bytes=$(echo "${desc}" | jq -r '.BytesTransferred // 0')
      est=$(echo "${desc}" | jq -r '.EstimatedBytesToTransfer // 0')
      files=$(echo "${desc}" | jq -r '.FilesTransferred // 0')
      verified=$(echo "${desc}" | jq -r '.BytesVerified // 0')
      skipped=$(echo "${desc}" | jq -r '.FilesSkipped // 0')
      err=$(echo "${desc}" | jq_safe '.ErrorCode')

      # Compute duration and progress
      local start_ts end_ts now_ts duration progress
      now_ts=$(date +%s)
      start_ts=$(date -d "${start}" +%s 2>/dev/null || echo 0)
      end_ts=$(date -d "${end}" +%s 2>/dev/null || echo 0)
      if (( end_ts > 0 )); then duration=$(( end_ts - start_ts )); else duration=$(( now_ts - start_ts )); fi
      if (( est > 0 )); then progress=$(( bytes * 100 / est )); else progress=0; fi

      echo "  Execution: ${e}" >> "${OUTPUT_FILE}"
      echo "    Status: ${status}" >> "${OUTPUT_FILE}"
      echo "    Start: ${start}" >> "${OUTPUT_FILE}"
      [[ -n "${end}" && "${end}" != "null" ]] && echo "    End: ${end}" >> "${OUTPUT_FILE}"
      echo "    Duration: ${duration}s" >> "${OUTPUT_FILE}"
      echo "    Progress: ${progress}% (${bytes}/${est} bytes)" >> "${OUTPUT_FILE}"
      echo "    Files: transferred=${files} skipped=${skipped} verifiedBytes=${verified}" >> "${OUTPUT_FILE}"

      # Flag failed
      if [[ "${status}" == "ERROR" ]]; then
        ((total_failed++)); ((failed_for_task++))
        echo "    WARNING: Execution failed (ErrorCode=${err})" >> "${OUTPUT_FILE}"
      fi

      # Flag potentially stuck running
      if [[ "${status}" == "LAUNCHING" || "${status}" == "QUEUED" || "${status}" == "PREPARING" || "${status}" == "TRANSFERRING" || "${status}" == "VERIFYING" ]]; then
        if (( duration >= stuck_threshold )); then
          ((total_stuck++))
          echo "    WARNING: Execution appears stuck (>${STUCK_MINUTES}m)" >> "${OUTPUT_FILE}"
        fi
      fi
    done

    if (( failed_for_task >= FAILED_THRESHOLD )); then
      echo "  WARNING: Task has >= ${FAILED_THRESHOLD} failed executions" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Summary:"
    echo "  Failed Executions: ${total_failed}"
    echo "  Potentially Stuck: ${total_stuck}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local tasks="$1"; local failures="$2"; local stuck="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS DataSync Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Tasks", "value": "${tasks}", "short": true},
        {"title": "Failed Executions", "value": "${failures}", "short": true},
        {"title": "Potentially Stuck", "value": "${stuck}", "short": true},
        {"title": "Lookback", "value": "${DAYS_BACK} days", "short": true},
        {"title": "Stuck Threshold", "value": "${STUCK_MINUTES} minutes", "short": true},
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
  log_message INFO "Starting AWS DataSync monitoring"
  write_header
  report_locations
  report_tasks_overview
  monitor_task_executions
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local task_count failed_count stuck_count
  task_count=$(list_tasks | wc -l | xargs || echo 0)
  failed_count=$(grep -c "Execution failed" "${OUTPUT_FILE}" || echo 0)
  stuck_count=$(grep -c "appears stuck" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${task_count}" "${failed_count}" "${stuck_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

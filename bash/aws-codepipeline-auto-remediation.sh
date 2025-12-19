#!/bin/bash

################################################################################
# AWS CodePipeline Auto-Remediation
# Automatically detects and retries failed pipeline executions with detailed
# notifications, failure analysis, and remediation tracking
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/codepipeline-remediation-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/codepipeline-remediation.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
DRY_RUN="${DRY_RUN:-false}"

# Remediation settings
AUTO_RETRY="${AUTO_RETRY:-true}"
MAX_RETRIES="${MAX_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-300}"                           # seconds
ANALYZE_FAILURES="${ANALYZE_FAILURES:-true}"
IGNORE_TRANSIENT="${IGNORE_TRANSIENT:-true}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

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

list_pipelines() {
  aws codepipeline list-pipelines \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"pipelines":[]}'
}

get_pipeline_state() {
  local pipeline_name="$1"
  aws codepipeline get-pipeline-state \
    --name "${pipeline_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"stageStates":[]}'
}

get_pipeline_execution() {
  local pipeline_name="$1"
  local execution_id="$2"
  aws codepipeline get-pipeline-execution \
    --pipeline-name "${pipeline_name}" \
    --pipeline-execution-id "${execution_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_pipeline_executions() {
  local pipeline_name="$1"
  aws codepipeline list-pipeline-executions \
    --pipeline-name "${pipeline_name}" \
    --region "${REGION}" \
    --max-results 10 \
    --output json 2>/dev/null || echo '{"pipelineExecutionSummaries":[]}'
}

retry_pipeline_execution() {
  local pipeline_name="$1"
  local stage_name="$2"
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "[DRY-RUN] Would retry pipeline ${pipeline_name} from stage ${stage_name}"
    return 0
  fi
  
  aws codepipeline retry-pipeline-execution \
    --pipeline-name "${pipeline_name}" \
    --pipeline-execution-id "$(get_latest_execution_id "${pipeline_name}")" \
    --retry-mode FAILED_ACTIONS \
    --region "${REGION}" \
    --output json 2>/dev/null || return 1
}

get_latest_execution_id() {
  local pipeline_name="$1"
  local executions
  executions=$(list_pipeline_executions "${pipeline_name}")
  echo "${executions}" | jq -r '.pipelineExecutionSummaries[0].pipelineExecutionId' 2>/dev/null || echo ""
}

get_action_execution_details() {
  local pipeline_name="$1"
  local action_name="$2"
  local execution_id="$3"
  
  aws codepipeline get-action-execution \
    --pipeline-name "${pipeline_name}" \
    --action-name "${action_name}" \
    --pipeline-execution-id "${execution_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

analyze_failure_logs() {
  local pipeline_name="$1"
  local stage_name="$2"
  local action_name="$3"
  
  # Try to get CloudWatch logs for the failure
  local log_group
  log_group="/aws/codepipeline/${pipeline_name}/${stage_name}"
  
  if aws logs describe-log-groups --log-group-name-prefix "${log_group}" --region "${REGION}" &>/dev/null; then
    local recent_logs
    recent_logs=$(aws logs filter-log-events \
      --log-group-name "${log_group}" \
      --start-time "$(($(date +%s) - 3600))000" \
      --region "${REGION}" \
      --query 'events[0:5].message' \
      --output text 2>/dev/null || echo "")
    
    if [[ -n "${recent_logs}" ]]; then
      echo "${recent_logs}"
      return 0
    fi
  fi
  
  return 1
}

is_transient_failure() {
  local error_message="$1"
  
  # Common transient errors
  local transient_patterns=(
    "timeout"
    "throttl"
    "temporarily"
    "service unavailable"
    "connection refused"
    "connection reset"
    "failed to connect"
    "rate exceeded"
  )
  
  local pattern
  for pattern in "${transient_patterns[@]}"; do
    if echo "${error_message}" | grep -qi "${pattern}"; then
      return 0
    fi
  done
  
  return 1
}

send_slack_alert() {
  local message="$1"
  local severity="$2"
  local details="${3:-}"
  
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    return
  fi
  
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    RETRY)    color="accent" ;;
    SUCCESS)  color="good" ;;
    *)        color="good" ;;
  esac
  
  local text="${message}"
  if [[ -n "${details}" ]]; then
    text="${message}\n\`\`\`${details}\`\`\`"
  fi
  
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "CodePipeline Remediation Alert",
      "text": "${text}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  curl -X POST -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK}" 2>/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then
    return
  fi
  
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS CodePipeline Auto-Remediation Report"
    echo "=========================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Auto-Retry Enabled: ${AUTO_RETRY}"
    echo "Max Retries: ${MAX_RETRIES}"
    echo "Dry Run Mode: ${DRY_RUN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

scan_pipelines() {
  log_message INFO "Starting CodePipeline scan"
  
  {
    echo "=== PIPELINE EXECUTION STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local total_pipelines=0
  local failed_executions=0
  local recovered_executions=0
  local retried_executions=0
  
  local pipelines_json
  pipelines_json=$(list_pipelines)
  
  local pipeline_names
  pipeline_names=$(echo "${pipelines_json}" | jq -r '.pipelines[].name' 2>/dev/null)
  
  if [[ -z "${pipeline_names}" ]]; then
    log_message WARN "No CodePipelines found in region ${REGION}"
    {
      echo "Status: No pipelines found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r pipeline_name; do
    ((total_pipelines++))
    
    log_message INFO "Scanning pipeline: ${pipeline_name}"
    
    # Get recent executions
    local executions_json
    executions_json=$(list_pipeline_executions "${pipeline_name}")
    
    local execution_ids
    execution_ids=$(echo "${executions_json}" | jq -r '.pipelineExecutionSummaries[].pipelineExecutionId' 2>/dev/null)
    
    if [[ -z "${execution_ids}" ]]; then
      continue
    fi
    
    while IFS= read -r execution_id; do
      if [[ -z "${execution_id}" ]]; then
        continue
      fi
      
      local exec_details
      exec_details=$(get_pipeline_execution "${pipeline_name}" "${execution_id}")
      
      local status
      local last_status_change
      local failed_stage=""
      local failed_action=""
      
      status=$(echo "${exec_details}" | jq_safe '.pipelineExecution.status')
      last_status_change=$(echo "${exec_details}" | jq_safe '.pipelineExecution.lastStatusChange')
      
      if [[ "${status}" != "Failed" ]]; then
        continue
      fi
      
      ((failed_executions++))
      
      # Find which stage/action failed
      local state_json
      state_json=$(get_pipeline_state "${pipeline_name}")
      
      local failed_info
      failed_info=$(echo "${state_json}" | jq -r '.stageStates[] | select(.latestExecution.status == "Failed") | "\(.stageName)|\(.actionStates[0].actionName)|\(.actionStates[0].latestExecution.errorDetails.message // "Unknown error")"' 2>/dev/null)
      
      if [[ -n "${failed_info}" ]]; then
        failed_stage=$(echo "${failed_info}" | cut -d'|' -f1)
        failed_action=$(echo "${failed_info}" | cut -d'|' -f2)
        local error_message=$(echo "${failed_info}" | cut -d'|' -f3)
        
        {
          echo "Pipeline: ${pipeline_name}"
          echo "Execution ID: ${execution_id}"
          echo "Status: ${status}"
          echo "Last Status Change: ${last_status_change}"
          echo "Failed Stage: ${failed_stage}"
          echo "Failed Action: ${failed_action}"
          echo "Error: ${error_message}"
          echo ""
        } >> "${OUTPUT_FILE}"
        
        log_message WARN "Pipeline ${pipeline_name} failed at stage ${failed_stage}/${failed_action}"
        
        # Analyze failure type
        local is_transient=false
        if [[ "${IGNORE_TRANSIENT}" == "true" ]]; then
          if is_transient_failure "${error_message}"; then
            is_transient=true
            {
              echo "Failure Type: Transient (auto-retryable)"
              echo ""
            } >> "${OUTPUT_FILE}"
            log_message INFO "Detected transient failure, attempting auto-retry"
          fi
        fi
        
        # Attempt remediation
        if [[ "${AUTO_RETRY}" == "true" && ("${is_transient}" == "true" || "${IGNORE_TRANSIENT}" != "true") ]]; then
          log_message INFO "Attempting to retry pipeline ${pipeline_name}"
          
          if retry_pipeline_execution "${pipeline_name}" "${failed_stage}"; then
            ((retried_executions++))
            {
              echo "Remediation: ✓ Retry initiated"
              echo ""
            } >> "${OUTPUT_FILE}"
            
            local alert_msg="✓ Auto-remediation initiated for pipeline: ${pipeline_name}\nStage: ${failed_stage}\nAction: ${failed_action}"
            send_slack_alert "${alert_msg}" "RETRY"
            log_message INFO "Auto-retry successful for ${pipeline_name}"
          else
            {
              echo "Remediation: ✗ Retry failed"
              echo ""
            } >> "${OUTPUT_FILE}"
            log_message ERROR "Auto-retry failed for ${pipeline_name}"
          fi
        else
          {
            echo "Remediation: Skipped (auto-retry disabled)"
            echo ""
          } >> "${OUTPUT_FILE}"
          
          local alert_msg="⚠️  Pipeline failure detected: ${pipeline_name}\nStage: ${failed_stage}\nAction: ${failed_action}\nError: ${error_message}"
          send_slack_alert "${alert_msg}" "CRITICAL"
          send_email_alert "CodePipeline Failure: ${pipeline_name}" "${alert_msg}"
        fi
      fi
      
    done <<< "${execution_ids}"
    
  done <<< "${pipeline_names}"
  
  # Summary
  {
    echo ""
    echo "=== REMEDIATION SUMMARY ==="
    echo "Total Pipelines Scanned: ${total_pipelines}"
    echo "Failed Executions Detected: ${failed_executions}"
    echo "Auto-Retry Initiated: ${retried_executions}"
    if [[ ${retried_executions} -gt 0 ]]; then
      recovered_executions=$((retried_executions))
      echo "Recovery Attempts: ${recovered_executions}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
  
  log_message INFO "Pipeline scan complete. Total: ${total_pipelines}, Failed: ${failed_executions}, Retried: ${retried_executions}"
}

list_recent_failures() {
  log_message INFO "Analyzing recent pipeline failures"
  
  {
    echo ""
    echo "=== RECENT FAILURE TIMELINE ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local pipelines_json
  pipelines_json=$(list_pipelines)
  
  local pipeline_names
  pipeline_names=$(echo "${pipelines_json}" | jq -r '.pipelines[].name' 2>/dev/null)
  
  while IFS= read -r pipeline_name; do
    local executions_json
    executions_json=$(list_pipeline_executions "${pipeline_name}")
    
    echo "${executions_json}" | jq -r '.pipelineExecutionSummaries[] | select(.status == "Failed") | "\(.lastStatusChange | split("T")[0])|\(.pipelineExecutionId)|\(.status)"' 2>/dev/null | while IFS='|' read -r date exec_id status; do
      {
        echo "[${date}] ${pipeline_name}/${exec_id}: ${status}"
      } >> "${OUTPUT_FILE}"
    done
  done <<< "${pipeline_names}"
}

main() {
  log_message INFO "=== CodePipeline Auto-Remediation Started ==="
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message WARN "Running in DRY-RUN mode - no actual retries will be performed"
    {
      echo ""
      echo "⚠️  DRY-RUN MODE ENABLED - No actual changes will be made"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
  
  write_header
  scan_pipelines
  list_recent_failures
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== CodePipeline Auto-Remediation Completed ==="
}

main "$@"

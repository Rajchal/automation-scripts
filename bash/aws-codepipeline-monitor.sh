#!/bin/bash

################################################################################
# AWS CodePipeline Monitor
# Monitors CodePipeline executions, stage status, deployment progress, approval
# actions, and provides insights on pipeline health and performance.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/codepipeline-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/codepipeline-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
PIPELINE_FAILURE_WARN="${PIPELINE_FAILURE_WARN:-5}"    # % failure rate
EXECUTION_TIME_WARN="${EXECUTION_TIME_WARN:-3600}"     # seconds (1 hour)
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_PIPELINES=0
FAILED_PIPELINES=0
PIPELINES_WITH_FAILURES=0
LONG_RUNNING_PIPELINES=0
PENDING_APPROVALS=0
TOTAL_EXECUTIONS=0
FAILED_EXECUTIONS=0

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
      "title": "CodePipeline Alert",
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
    echo "AWS CodePipeline Monitor"
    echo "========================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback Period: ${LOOKBACK_DAYS} days"
    echo ""
    echo "Thresholds:"
    echo "  Failure Rate Warning: ${PIPELINE_FAILURE_WARN}%"
    echo "  Execution Time Warning: ${EXECUTION_TIME_WARN}s"
    echo ""
  } > "${OUTPUT_FILE}"
}

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
    --output json 2>/dev/null || echo '{}'
}

list_pipeline_executions() {
  local pipeline_name="$1"
  aws codepipeline list-pipeline-executions \
    --pipeline-name "${pipeline_name}" \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"pipelineExecutionSummaries":[]}'
}

get_pipeline_execution() {
  local pipeline_name="$1"
  local pipeline_execution_id="$2"
  aws codepipeline get-pipeline-execution \
    --pipeline-name "${pipeline_name}" \
    --pipeline-execution-id "${pipeline_execution_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_pipeline() {
  local pipeline_name="$1"
  aws codepipeline get-pipeline \
    --name "${pipeline_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

put_approval_result() {
  # This is for future use if automation decides to approve/reject
  # Not actively used in monitoring, but available for integration
  :
}

list_webhooks() {
  aws codepipeline list-webhooks \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"webhooks":[]}'
}

monitor_pipelines() {
  log_message INFO "Starting CodePipeline monitoring"
  
  {
    echo "=== CODEPIPELINE INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local pipelines_json
  pipelines_json=$(list_pipelines)
  
  local pipeline_count
  pipeline_count=$(echo "${pipelines_json}" | jq '.pipelines | length' 2>/dev/null || echo "0")
  
  TOTAL_PIPELINES=${pipeline_count}
  
  if [[ ${pipeline_count} -eq 0 ]]; then
    {
      echo "No CodePipelines found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Pipelines: ${pipeline_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local pipelines
  pipelines=$(echo "${pipelines_json}" | jq -r '.pipelines[].name' 2>/dev/null)
  
  while IFS= read -r pipeline_name; do
    [[ -z "${pipeline_name}" ]] && continue
    
    log_message INFO "Analyzing pipeline: ${pipeline_name}"
    
    {
      echo "=== PIPELINE: ${pipeline_name} ==="
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get pipeline details
    analyze_pipeline_definition "${pipeline_name}"
    
    # Get current state
    monitor_pipeline_state "${pipeline_name}"
    
    # Get execution history
    analyze_execution_history "${pipeline_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${pipelines}"
}

analyze_pipeline_definition() {
  local pipeline_name="$1"
  
  {
    echo "Pipeline Configuration:"
  } >> "${OUTPUT_FILE}"
  
  local pipeline_json
  pipeline_json=$(get_pipeline "${pipeline_name}")
  
  local artifact_store
  artifact_store=$(echo "${pipeline_json}" | jq_safe '.pipeline.artifactStore.location')
  
  {
    echo "  Artifact Store: ${artifact_store}"
  } >> "${OUTPUT_FILE}"
  
  # Count stages
  local stage_count
  stage_count=$(echo "${pipeline_json}" | jq '.pipeline.stages | length' 2>/dev/null || echo "0")
  
  {
    echo "  Total Stages: ${stage_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${stage_count} -gt 0 ]]; then
    {
      echo "  Stages:"
    } >> "${OUTPUT_FILE}"
    
    local stages
    stages=$(echo "${pipeline_json}" | jq -c '.pipeline.stages[]' 2>/dev/null)
    
    while IFS= read -r stage; do
      [[ -z "${stage}" ]] && continue
      
      local stage_name action_count
      stage_name=$(echo "${stage}" | jq_safe '.name')
      action_count=$(echo "${stage}" | jq '.actions | length' 2>/dev/null || echo "0")
      
      {
        echo "    - ${stage_name}: ${action_count} actions"
      } >> "${OUTPUT_FILE}"
      
    done <<< "${stages}"
  fi
  
  # Check for triggers
  local trigger_type
  trigger_type=$(echo "${pipeline_json}" | jq_safe '.pipeline.triggers[0].type // "Manual"')
  
  {
    echo "  Trigger Type: ${trigger_type}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_pipeline_state() {
  local pipeline_name="$1"
  
  {
    echo "Current Pipeline State:"
  } >> "${OUTPUT_FILE}"
  
  local state_json
  state_json=$(get_pipeline_state "${pipeline_name}")
  
  local pipeline_version created_time
  pipeline_version=$(echo "${state_json}" | jq_safe '.pipelineVersion // "N/A"')
  created_time=$(echo "${state_json}" | jq_safe '.created')
  
  {
    echo "  Version: ${pipeline_version}"
    echo "  Created: ${created_time}"
  } >> "${OUTPUT_FILE}"
  
  # Analyze stage states
  local stages
  stages=$(echo "${state_json}" | jq -c '.stageStates[]' 2>/dev/null)
  
  if [[ -z "${stages}" ]]; then
    {
      echo "  No stage states available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo ""
    echo "  Stage States:"
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r stage; do
    [[ -z "${stage}" ]] && continue
    
    local stage_name stage_status latest_execution
    stage_name=$(echo "${stage}" | jq_safe '.stageName')
    stage_status=$(echo "${stage}" | jq_safe '.latestExecution.status')
    latest_execution=$(echo "${stage}" | jq_safe '.latestExecution.lastStatusChange')
    
    {
      echo "    Stage: ${stage_name}"
      echo "      Status: ${stage_status}"
      echo "      Last Updated: ${latest_execution}"
    } >> "${OUTPUT_FILE}"
    
    # Check action states
    local actions
    actions=$(echo "${stage}" | jq -c '.actionStates[]' 2>/dev/null)
    
    if [[ -n "${actions}" ]]; then
      {
        echo "      Actions:"
      } >> "${OUTPUT_FILE}"
      
      while IFS= read -r action; do
        [[ -z "${action}" ]] && continue
        
        local action_name action_status
        action_name=$(echo "${action}" | jq_safe '.actionName')
        action_status=$(echo "${action}" | jq_safe '.latestExecution.status')
        
        {
          echo "        - ${action_name}: ${action_status}"
        } >> "${OUTPUT_FILE}"
        
        # Check for approval
        local approval_token approval_comment
        approval_token=$(echo "${action}" | jq_safe '.latestExecution.token // ""')
        approval_comment=$(echo "${action}" | jq_safe '.latestExecution.externalExecutionDetails.summary // ""')
        
        if [[ -n "${approval_token}" ]]; then
          ((PENDING_APPROVALS++))
          {
            printf "          %b⏸️  PENDING APPROVAL%b\n" "${YELLOW}" "${NC}"
            if [[ -n "${approval_comment}" ]]; then
              echo "          Comment: ${approval_comment}"
            fi
          } >> "${OUTPUT_FILE}"
          log_message WARN "Pipeline ${pipeline_name} has pending approval in ${action_name}"
        fi
        
        # Check for errors
        local error_details
        error_details=$(echo "${action}" | jq_safe '.latestExecution.errorDetails.message // ""')
        
        if [[ -n "${error_details}" ]]; then
          {
            printf "          %b✗ Error: %s%b\n" "${RED}" "${error_details}" "${NC}"
          } >> "${OUTPUT_FILE}"
          log_message ERROR "Pipeline ${pipeline_name} action ${action_name} error: ${error_details}"
        fi
        
      done <<< "${actions}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stages}"
}

analyze_execution_history() {
  local pipeline_name="$1"
  
  {
    echo "Execution History (Last 20):"
  } >> "${OUTPUT_FILE}"
  
  local executions_json
  executions_json=$(list_pipeline_executions "${pipeline_name}")
  
  local execution_count
  execution_count=$(echo "${executions_json}" | jq '.pipelineExecutionSummaries | length' 2>/dev/null || echo "0")
  
  TOTAL_EXECUTIONS=$((TOTAL_EXECUTIONS + execution_count))
  
  if [[ ${execution_count} -eq 0 ]]; then
    {
      echo "  No execution history available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Total Executions: ${execution_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local executions
  executions=$(echo "${executions_json}" | jq -c '.pipelineExecutionSummaries[]' 2>/dev/null | head -20)
  
  local failed_count=0
  local success_count=0
  
  while IFS= read -r execution; do
    [[ -z "${execution}" ]] && continue
    
    local exec_id status start_time end_time
    exec_id=$(echo "${execution}" | jq_safe '.pipelineExecutionId')
    status=$(echo "${execution}" | jq_safe '.status')
    start_time=$(echo "${execution}" | jq_safe '.startTime')
    end_time=$(echo "${execution}" | jq_safe '.lastStatusChange')
    
    {
      echo "  Execution: ${exec_id}"
      echo "    Status: ${status}"
      echo "    Started: ${start_time}"
    } >> "${OUTPUT_FILE}"
    
    # Calculate execution duration
    if [[ -n "${start_time}" && -n "${end_time}" ]]; then
      local start_epoch end_epoch duration
      start_epoch=$(date -d "${start_time}" +%s 2>/dev/null || echo "0")
      end_epoch=$(date -d "${end_time}" +%s 2>/dev/null || echo "0")
      duration=$((end_epoch - start_epoch))
      
      if [[ ${duration} -gt 0 ]]; then
        local minutes seconds
        minutes=$((duration / 60))
        seconds=$((duration % 60))
        
        {
          echo "    Duration: ${minutes}m ${seconds}s"
        } >> "${OUTPUT_FILE}"
        
        if [[ ${duration} -gt ${EXECUTION_TIME_WARN} ]]; then
          ((LONG_RUNNING_PIPELINES++))
          {
            printf "    %b⚠️  Long execution time%b\n" "${YELLOW}" "${NC}"
          } >> "${OUTPUT_FILE}"
        fi
      fi
    fi
    
    # Track success/failure
    case "${status}" in
      Succeeded)
        ((success_count++))
        {
          printf "    %b✓ Execution Succeeded%b\n" "${GREEN}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ;;
      Failed)
        ((failed_count++))
        ((FAILED_EXECUTIONS++))
        ((PIPELINES_WITH_FAILURES++))
        {
          printf "    %b✗ Execution Failed%b\n" "${RED}" "${NC}"
        } >> "${OUTPUT_FILE}"
        log_message ERROR "Pipeline ${pipeline_name} execution ${exec_id} failed"
        ;;
      InProgress)
        {
          printf "    %b⚙️  In Progress%b\n" "${CYAN}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ;;
      Stopped)
        {
          printf "    %b⏹️  Stopped%b\n" "${YELLOW}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ;;
    esac
    
    # Get detailed execution info
    get_execution_details "${pipeline_name}" "${exec_id}"
    
  done <<< "${executions}"
  
  # Calculate failure rate
  if [[ ${execution_count} -gt 0 ]]; then
    local failure_rate
    failure_rate=$(echo "scale=2; ${failed_count} * 100 / ${execution_count}" | bc -l 2>/dev/null || echo "0")
    
    {
      echo ""
      echo "  Success Rate: $((100 - ${failure_rate%.*}))%"
      echo "  Failure Rate: ${failure_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${failure_rate} > ${PIPELINE_FAILURE_WARN}" | bc -l) )); then
      ((FAILED_PIPELINES++))
      {
        printf "  %b⚠️  High failure rate detected%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Pipeline ${pipeline_name} failure rate: ${failure_rate}%"
    fi
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

get_execution_details() {
  local pipeline_name="$1"
  local execution_id="$2"
  
  local exec_json
  exec_json=$(get_pipeline_execution "${pipeline_name}" "${execution_id}")
  
  local stage_executions
  stage_executions=$(echo "${exec_json}" | jq -c '.pipelineExecution.stageExecutions[]?' 2>/dev/null)
  
  if [[ -z "${stage_executions}" ]]; then
    return
  fi
  
  {
    echo "    Stages:"
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r stage_exec; do
    [[ -z "${stage_exec}" ]] && continue
    
    local stage_name stage_status
    stage_name=$(echo "${stage_exec}" | jq_safe '.stageName')
    stage_status=$(echo "${stage_exec}" | jq_safe '.status')
    
    {
      echo "      - ${stage_name}: ${stage_status}"
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stage_executions}"
}

monitor_webhooks() {
  log_message INFO "Monitoring pipeline webhooks"
  
  {
    echo "=== PIPELINE WEBHOOKS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local webhooks_json
  webhooks_json=$(list_webhooks)
  
  local webhook_count
  webhook_count=$(echo "${webhooks_json}" | jq '.webhooks | length' 2>/dev/null || echo "0")
  
  if [[ ${webhook_count} -eq 0 ]]; then
    {
      echo "No webhooks configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Webhooks: ${webhook_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local webhooks
  webhooks=$(echo "${webhooks_json}" | jq -c '.webhooks[]' 2>/dev/null)
  
  while IFS= read -r webhook; do
    [[ -z "${webhook}" ]] && continue
    
    local webhook_name pipeline_name
    webhook_name=$(echo "${webhook}" | jq_safe '.definition.name')
    pipeline_name=$(echo "${webhook}" | jq_safe '.definition.targetPipeline')
    
    {
      echo "Webhook: ${webhook_name}"
      echo "  Pipeline: ${pipeline_name}"
    } >> "${OUTPUT_FILE}"
    
    # Check if webhook is active
    local is_active
    is_active=$(echo "${webhook}" | jq_safe '.lastTriggered // "Never"')
    
    {
      echo "  Last Triggered: ${is_active}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${webhooks}"
}

generate_summary() {
  {
    echo ""
    echo "=== CODEPIPELINE SUMMARY ==="
    echo ""
    printf "Total Pipelines: %d\n" "${TOTAL_PIPELINES}"
    printf "Pipelines with Failures: %d\n" "${FAILED_PIPELINES}"
    printf "Total Executions (Recent): %d\n" "${TOTAL_EXECUTIONS}"
    printf "Failed Executions: %d\n" "${FAILED_EXECUTIONS}"
    printf "Long Running Pipelines: %d\n" "${LONG_RUNNING_PIPELINES}"
    printf "Pending Approvals: %d\n" "${PENDING_APPROVALS}"
    echo ""
    
    if [[ ${FAILED_PIPELINES} -gt 0 ]] || [[ ${PENDING_APPROVALS} -gt 0 ]]; then
      printf "%b[CRITICAL] Pipeline failures or approvals pending%b\n" "${RED}" "${NC}"
    elif [[ ${LONG_RUNNING_PIPELINES} -gt 0 ]]; then
      printf "%b[WARNING] Performance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All pipelines operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${PENDING_APPROVALS} -gt 0 ]]; then
      echo "Approval Action Items:"
      echo "  • Review pending approval requests immediately"
      echo "  • Set up SNS notifications for approval actions"
      echo "  • Configure auto-approval for trusted sources"
      echo "  • Establish approval process documentation"
      echo "  • Monitor approval time for delays"
      echo "  • Set timeout on approval stages (max 7 days)"
      echo ""
    fi
    
    if [[ ${FAILED_PIPELINES} -gt 0 ]]; then
      echo "Failed Pipeline Recovery:"
      echo "  • Review detailed execution logs in CloudWatch"
      echo "  • Check stage-specific logs for root cause"
      echo "  • Verify artifact repository accessibility"
      echo "  • Review IAM role permissions for pipeline"
      echo "  • Check service limits and capacity"
      echo "  • Retry failed execution or manual trigger"
      echo "  • Implement automated retry logic"
      echo ""
    fi
    
    if [[ ${LONG_RUNNING_PIPELINES} -gt 0 ]]; then
      echo "Pipeline Performance Optimization:"
      echo "  • Parallelize independent stages where possible"
      echo "  • Optimize build and test duration"
      echo "  • Use caching (build artifacts, dependencies)"
      echo "  • Reduce artifact size for faster transfers"
      echo "  • Implement incremental builds"
      echo "  • Review CodeBuild performance settings"
      echo "  • Consider increasing resource allocation"
      echo ""
    fi
    
    echo "Best Practices:"
    echo "  • Use CloudFormation for infrastructure as code"
    echo "  • Implement multi-stage pipelines (Dev/Stage/Prod)"
    echo "  • Use parameter store for configuration management"
    echo "  • Enable manual approval gates for production"
    echo "  • Implement automated testing in early stages"
    echo "  • Use artifact versioning for rollback capability"
    echo "  • Store secrets in AWS Secrets Manager"
    echo "  • Enable deployment notifications via SNS/SQS"
    echo "  • Implement pre-deployment health checks"
    echo ""
    
    echo "Security Hardening:"
    echo "  • Use IAM roles with least privilege permissions"
    echo "  • Enable MFA delete on artifact bucket"
    echo "  • Encrypt artifacts in transit and at rest"
    echo "  • Use VPC endpoints for private connectivity"
    echo "  • Enable CloudTrail logging for audit"
    echo "  • Implement code scanning in build stage"
    echo "  • Use code signing for binary artifacts"
    echo "  • Rotate credentials regularly"
    echo "  • Implement RBAC for approval actions"
    echo ""
    
    echo "Monitoring & Alerting:"
    echo "  • Set CloudWatch alarms on failed executions"
    echo "  • Monitor execution duration for anomalies"
    echo "  • Alert on approval timeout"
    echo "  • Track deployment success rate"
    echo "  • Monitor artifact repository metrics"
    echo "  • Use EventBridge for pipeline state changes"
    echo "  • Integrate with Slack/Teams for notifications"
    echo "  • Monitor CodeBuild failures by stage"
    echo "  • Track rollback frequency"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • CodePipeline costs: \$1 per active pipeline/month"
    echo "  • Optimize CodeBuild resource allocation"
    echo "  • Use build cache to reduce build time"
    echo "  • Clean up old artifacts regularly"
    echo "  • Use spot instances for non-critical builds"
    echo "  • Monitor artifact storage costs"
    echo "  • Compress artifacts before storage"
    echo ""
    
    echo "Deployment Strategies:"
    echo "  • Blue/green deployments for zero-downtime"
    echo "  • Canary deployments for risk mitigation"
    echo "  • Rolling updates for gradual rollout"
    echo "  • Feature flags for progressive enablement"
    echo "  • Automated rollback on failure"
    echo "  • Health check integration pre-deployment"
    echo "  • Smoke test validation in each stage"
    echo ""
    
    echo "Integration Points:"
    echo "  • CodeCommit: Source control integration"
    echo "  • CodeBuild: Build and test automation"
    echo "  • CodeDeploy: Deployment automation"
    echo "  • CloudFormation: Infrastructure provisioning"
    echo "  • Lambda: Serverless workflow automation"
    echo "  • SNS: Notifications and alerts"
    echo "  • CloudWatch: Metrics and logs"
    echo "  • EventBridge: Event-driven automation"
    echo "  • Service Catalog: Automated approvals"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== CodePipeline Monitor Started ==="
  
  write_header
  monitor_pipelines
  monitor_webhooks
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS CodePipeline Documentation:"
    echo "  https://docs.aws.amazon.com/codepipeline/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== CodePipeline Monitor Completed ==="
  
  # Send alerts
  if [[ ${FAILED_PIPELINES} -gt 0 ]] || [[ ${PENDING_APPROVALS} -gt 0 ]]; then
    send_slack_alert "🚨 ${FAILED_PIPELINES} pipeline(s) with failures, ${PENDING_APPROVALS} approvals pending" "CRITICAL"
    send_email_alert "CodePipeline Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${LONG_RUNNING_PIPELINES} -gt 0 ]]; then
    send_slack_alert "⚠️ ${LONG_RUNNING_PIPELINES} pipeline(s) with extended execution time" "WARNING"
  fi
}

main "$@"

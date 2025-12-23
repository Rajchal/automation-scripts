#!/bin/bash

################################################################################
# AWS CloudFormation Stack Monitor
# Monitors CloudFormation stacks for drift detection, failed resources, stack
# status, nested stacks, and provides detailed analysis and recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/cloudformation-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/cloudformation-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
STACK_AGE_WARN_DAYS="${STACK_AGE_WARN_DAYS:-365}"  # Warn for stacks older than 1 year
DRIFT_CHECK_AGE_HOURS="${DRIFT_CHECK_AGE_HOURS:-168}" # Warn if drift not checked in 7 days

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_STACKS=0
FAILED_STACKS=0
DRIFTED_STACKS=0
ROLLBACK_STACKS=0
STALE_STACKS=0
DRIFT_DETECTION_FAILED=0
NESTED_STACKS=0

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
      "title": "CloudFormation Alert",
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
    echo "AWS CloudFormation Stack Monitor"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
    echo "Thresholds:"
    echo "  Stack Age Warning: ${STACK_AGE_WARN_DAYS} days"
    echo "  Drift Check Age: ${DRIFT_CHECK_AGE_HOURS} hours"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_stacks() {
  aws cloudformation list-stacks \
    --region "${REGION}" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      CREATE_FAILED ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED DELETE_FAILED \
    --output json 2>/dev/null || echo '{"StackSummaries":[]}'
}

describe_stack() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Stacks":[]}'
}

describe_stack_resources() {
  local stack_name="$1"
  aws cloudformation describe-stack-resources \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"StackResources":[]}'
}

detect_stack_drift() {
  local stack_name="$1"
  aws cloudformation detect-stack-drift \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_stack_drift_detection_status() {
  local drift_detection_id="$1"
  aws cloudformation describe-stack-drift-detection-status \
    --stack-drift-detection-id "${drift_detection_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_stack_resource_drifts() {
  local stack_name="$1"
  aws cloudformation describe-stack-resource-drifts \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"StackResourceDrifts":[]}'
}

get_stack_events() {
  local stack_name="$1"
  aws cloudformation describe-stack-events \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --max-items 20 \
    --output json 2>/dev/null || echo '{"StackEvents":[]}'
}

list_stack_sets() {
  aws cloudformation list-stack-sets \
    --region "${REGION}" \
    --status ACTIVE \
    --output json 2>/dev/null || echo '{"Summaries":[]}'
}

monitor_stacks() {
  log_message INFO "Starting CloudFormation stack monitoring"
  
  {
    echo "=== CLOUDFORMATION STACK INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local stacks_json
  stacks_json=$(list_stacks)
  
  local count
  count=$(echo "${stacks_json}" | jq '.StackSummaries | length' 2>/dev/null || echo "0")
  
  TOTAL_STACKS=${count}
  
  if [[ ${count} -eq 0 ]]; then
    {
      echo "No CloudFormation stacks found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Stacks: ${count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local stacks
  stacks=$(echo "${stacks_json}" | jq -c '.StackSummaries[]' 2>/dev/null)
  
  while IFS= read -r stack; do
    [[ -z "${stack}" ]] && continue
    
    local stack_name stack_status creation_time
    stack_name=$(echo "${stack}" | jq_safe '.StackName')
    stack_status=$(echo "${stack}" | jq_safe '.StackStatus')
    creation_time=$(echo "${stack}" | jq_safe '.CreationTime')
    
    log_message INFO "Analyzing stack: ${stack_name}"
    
    {
      echo "=== STACK: ${stack_name} ==="
      echo ""
      echo "Status: ${stack_status}"
      echo "Created: ${creation_time}"
    } >> "${OUTPUT_FILE}"
    
    # Get detailed information
    local stack_detail
    stack_detail=$(describe_stack "${stack_name}")
    
    analyze_stack_details "${stack_detail}" "${stack_name}" "${stack_status}"
    analyze_stack_resources "${stack_name}"
    check_drift_status "${stack_name}"
    get_recent_events "${stack_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stacks}"
}

analyze_stack_details() {
  local stack_detail="$1"
  local stack_name="$2"
  local stack_status="$3"
  
  local stack_info
  stack_info=$(echo "${stack_detail}" | jq -c '.Stacks[0]' 2>/dev/null)
  
  if [[ -z "${stack_info}" || "${stack_info}" == "null" ]]; then
    {
      echo "  Unable to retrieve stack details"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local description parent_id root_id
  description=$(echo "${stack_info}" | jq_safe '.Description // "N/A"')
  parent_id=$(echo "${stack_info}" | jq_safe '.ParentId // ""')
  root_id=$(echo "${stack_info}" | jq_safe '.RootId // ""')
  
  {
    echo "Description: ${description}"
  } >> "${OUTPUT_FILE}"
  
  # Check if nested stack
  if [[ -n "${parent_id}" ]]; then
    ((NESTED_STACKS++))
    {
      echo "Type: Nested Stack"
      echo "Parent ID: ${parent_id}"
      echo "Root ID: ${root_id}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Check stack age
  local creation_time last_updated
  creation_time=$(echo "${stack_info}" | jq_safe '.CreationTime')
  last_updated=$(echo "${stack_info}" | jq_safe '.LastUpdatedTime // .CreationTime')
  
  if [[ -n "${creation_time}" ]]; then
    local creation_epoch current_epoch age_days
    creation_epoch=$(date -d "${creation_time}" +%s 2>/dev/null || echo "0")
    current_epoch=$(date +%s)
    age_days=$(( (current_epoch - creation_epoch) / 86400 ))
    
    {
      echo "Age: ${age_days} days"
      echo "Last Updated: ${last_updated}"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${age_days} -gt ${STACK_AGE_WARN_DAYS} ]]; then
      ((STALE_STACKS++))
      {
        printf "%b⚠️  Stack is older than ${STACK_AGE_WARN_DAYS} days%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Stack ${stack_name} is ${age_days} days old"
    fi
  fi
  
  # Check stack status
  case "${stack_status}" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      {
        printf "%b✓ Stack ${stack_status}%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ;;
    *ROLLBACK*|*FAILED*)
      ((FAILED_STACKS++))
      {
        printf "%b⚠️  Stack Status: ${stack_status}%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message ERROR "Stack ${stack_name} status: ${stack_status}"
      ;;
    *)
      {
        printf "%b⚠️  Stack Status: ${stack_status}%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ;;
  esac
  
  # Check termination protection
  local termination_protection
  termination_protection=$(echo "${stack_info}" | jq_safe '.EnableTerminationProtection')
  
  {
    echo "Termination Protection: ${termination_protection}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${termination_protection}" == "false" ]]; then
    {
      printf "%b⚠️  Termination protection disabled%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Check rollback configuration
  local rollback_enabled
  rollback_enabled=$(echo "${stack_info}" | jq '.RollbackConfiguration.RollbackTriggers | length' 2>/dev/null || echo "0")
  
  {
    echo "Rollback Triggers: ${rollback_enabled}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_stack_resources() {
  local stack_name="$1"
  
  {
    echo "Stack Resources:"
  } >> "${OUTPUT_FILE}"
  
  local resources_json
  resources_json=$(describe_stack_resources "${stack_name}")
  
  local resource_count
  resource_count=$(echo "${resources_json}" | jq '.StackResources | length' 2>/dev/null || echo "0")
  
  {
    echo "  Total Resources: ${resource_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${resource_count} -eq 0 ]]; then
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Count resources by type
  local resource_types
  resource_types=$(echo "${resources_json}" | jq -r '.StackResources[].ResourceType' 2>/dev/null | sort | uniq -c | sort -rn)
  
  {
    echo "  Resources by Type:"
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    {
      echo "    ${line}"
    } >> "${OUTPUT_FILE}"
  done <<< "${resource_types}"
  
  # Check for failed resources
  local failed_resources
  failed_resources=$(echo "${resources_json}" | jq -r '.StackResources[] | select(.ResourceStatus | contains("FAILED")) | .LogicalResourceId' 2>/dev/null)
  
  if [[ -n "${failed_resources}" ]]; then
    {
      echo ""
      printf "  %b⚠️  Failed Resources:%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    
    while IFS= read -r resource_id; do
      [[ -z "${resource_id}" ]] && continue
      
      local resource_status reason
      resource_status=$(echo "${resources_json}" | jq -r --arg id "${resource_id}" '.StackResources[] | select(.LogicalResourceId == $id) | .ResourceStatus' 2>/dev/null)
      reason=$(echo "${resources_json}" | jq -r --arg id "${resource_id}" '.StackResources[] | select(.LogicalResourceId == $id) | .ResourceStatusReason // "N/A"' 2>/dev/null)
      
      {
        echo "    - ${resource_id}"
        echo "      Status: ${resource_status}"
        echo "      Reason: ${reason}"
      } >> "${OUTPUT_FILE}"
    done <<< "${failed_resources}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_drift_status() {
  local stack_name="$1"
  
  {
    echo "Drift Detection:"
  } >> "${OUTPUT_FILE}"
  
  # Initiate drift detection
  local drift_json
  drift_json=$(detect_stack_drift "${stack_name}")
  
  local drift_id
  drift_id=$(echo "${drift_json}" | jq_safe '.StackDriftDetectionId')
  
  if [[ -z "${drift_id}" || "${drift_id}" == "null" ]]; then
    ((DRIFT_DETECTION_FAILED++))
    {
      printf "  %b⚠️  Unable to initiate drift detection%b\n" "${YELLOW}" "${NC}"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Wait for drift detection to complete (max 30 seconds)
  local attempts=0
  local max_attempts=10
  local detection_status=""
  
  while [[ ${attempts} -lt ${max_attempts} ]]; do
    sleep 3
    local status_json
    status_json=$(describe_stack_drift_detection_status "${drift_id}")
    detection_status=$(echo "${status_json}" | jq_safe '.DetectionStatus')
    
    if [[ "${detection_status}" == "DETECTION_COMPLETE" ]]; then
      break
    elif [[ "${detection_status}" == "DETECTION_FAILED" ]]; then
      {
        printf "  %b⚠️  Drift detection failed%b\n" "${RED}" "${NC}"
        echo ""
      } >> "${OUTPUT_FILE}"
      return
    fi
    
    ((attempts++))
  done
  
  if [[ "${detection_status}" != "DETECTION_COMPLETE" ]]; then
    {
      echo "  Drift detection in progress..."
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Get drift results
  local status_json
  status_json=$(describe_stack_drift_detection_status "${drift_id}")
  
  local drift_status drifted_count timestamp
  drift_status=$(echo "${status_json}" | jq_safe '.StackDriftStatus')
  drifted_count=$(echo "${status_json}" | jq_safe '.DriftedStackResourceCount // 0')
  timestamp=$(echo "${status_json}" | jq_safe '.Timestamp')
  
  {
    echo "  Status: ${drift_status}"
    echo "  Drifted Resources: ${drifted_count}"
    echo "  Last Checked: ${timestamp}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${drift_status}" == "DRIFTED" ]]; then
    ((DRIFTED_STACKS++))
    {
      printf "  %b⚠️  Stack has drifted from template%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Stack ${stack_name} has ${drifted_count} drifted resources"
    
    # Get drift details
    analyze_resource_drifts "${stack_name}"
  elif [[ "${drift_status}" == "IN_SYNC" ]]; then
    {
      printf "  %b✓ Stack is in sync with template%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_resource_drifts() {
  local stack_name="$1"
  
  {
    echo "  Drifted Resources:"
  } >> "${OUTPUT_FILE}"
  
  local drifts_json
  drifts_json=$(describe_stack_resource_drifts "${stack_name}")
  
  local drifts
  drifts=$(echo "${drifts_json}" | jq -c '.StackResourceDrifts[] | select(.StackResourceDriftStatus == "MODIFIED" or .StackResourceDriftStatus == "DELETED")' 2>/dev/null)
  
  if [[ -z "${drifts}" ]]; then
    {
      echo "    No detailed drift information available"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r drift; do
    [[ -z "${drift}" ]] && continue
    
    local logical_id resource_type drift_status
    logical_id=$(echo "${drift}" | jq_safe '.LogicalResourceId')
    resource_type=$(echo "${drift}" | jq_safe '.ResourceType')
    drift_status=$(echo "${drift}" | jq_safe '.StackResourceDriftStatus')
    
    {
      echo "    - ${logical_id}"
      echo "      Type: ${resource_type}"
      echo "      Drift Status: ${drift_status}"
    } >> "${OUTPUT_FILE}"
    
    # Show property differences
    local property_diffs
    property_diffs=$(echo "${drift}" | jq -c '.PropertyDifferences[]?' 2>/dev/null)
    
    if [[ -n "${property_diffs}" ]]; then
      {
        echo "      Property Differences:"
      } >> "${OUTPUT_FILE}"
      
      while IFS= read -r prop_diff; do
        [[ -z "${prop_diff}" ]] && continue
        
        local property_path diff_type
        property_path=$(echo "${prop_diff}" | jq_safe '.PropertyPath')
        diff_type=$(echo "${prop_diff}" | jq_safe '.DifferenceType')
        
        {
          echo "        - ${property_path}: ${diff_type}"
        } >> "${OUTPUT_FILE}"
      done <<< "${property_diffs}"
    fi
    
  done <<< "${drifts}"
}

get_recent_events() {
  local stack_name="$1"
  
  {
    echo "Recent Events (Last 10):"
  } >> "${OUTPUT_FILE}"
  
  local events_json
  events_json=$(get_stack_events "${stack_name}")
  
  local events
  events=$(echo "${events_json}" | jq -c '.StackEvents[] | select(.ResourceStatus != null)' 2>/dev/null | head -10)
  
  if [[ -z "${events}" ]]; then
    {
      echo "  No recent events"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r event; do
    [[ -z "${event}" ]] && continue
    
    local timestamp resource_id resource_status reason
    timestamp=$(echo "${event}" | jq_safe '.Timestamp')
    resource_id=$(echo "${event}" | jq_safe '.LogicalResourceId')
    resource_status=$(echo "${event}" | jq_safe '.ResourceStatus')
    reason=$(echo "${event}" | jq_safe '.ResourceStatusReason // ""')
    
    {
      echo "  ${timestamp}"
      echo "    Resource: ${resource_id}"
      echo "    Status: ${resource_status}"
      if [[ -n "${reason}" ]]; then
        echo "    Reason: ${reason}"
      fi
    } >> "${OUTPUT_FILE}"
    
  done <<< "${events}"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_stack_sets() {
  log_message INFO "Monitoring CloudFormation StackSets"
  
  {
    echo "=== CLOUDFORMATION STACKSETS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local stacksets_json
  stacksets_json=$(list_stack_sets)
  
  local count
  count=$(echo "${stacksets_json}" | jq '.Summaries | length' 2>/dev/null || echo "0")
  
  if [[ ${count} -eq 0 ]]; then
    {
      echo "No StackSets found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total StackSets: ${count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local stacksets
  stacksets=$(echo "${stacksets_json}" | jq -c '.Summaries[]' 2>/dev/null)
  
  while IFS= read -r stackset; do
    [[ -z "${stackset}" ]] && continue
    
    local stackset_name status drift_status
    stackset_name=$(echo "${stackset}" | jq_safe '.StackSetName')
    status=$(echo "${stackset}" | jq_safe '.Status')
    drift_status=$(echo "${stackset}" | jq_safe '.DriftStatus // "N/A"')
    
    {
      echo "StackSet: ${stackset_name}"
      echo "  Status: ${status}"
      echo "  Drift Status: ${drift_status}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stacksets}"
}

generate_summary() {
  {
    echo ""
    echo "=== CLOUDFORMATION SUMMARY ==="
    echo ""
    printf "Total Stacks: %d\n" "${TOTAL_STACKS}"
    printf "Failed/Rollback Stacks: %d\n" "${FAILED_STACKS}"
    printf "Drifted Stacks: %d\n" "${DRIFTED_STACKS}"
    printf "Stale Stacks (>%d days): %d\n" "${STACK_AGE_WARN_DAYS}" "${STALE_STACKS}"
    printf "Nested Stacks: %d\n" "${NESTED_STACKS}"
    printf "Drift Detection Failed: %d\n" "${DRIFT_DETECTION_FAILED}"
    echo ""
    
    if [[ ${FAILED_STACKS} -gt 0 ]] || [[ ${DRIFTED_STACKS} -gt 0 ]]; then
      printf "%b[CRITICAL] Stack issues detected%b\n" "${RED}" "${NC}"
    elif [[ ${STALE_STACKS} -gt 0 ]]; then
      printf "%b[WARNING] Stale stacks detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All stacks operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${FAILED_STACKS} -gt 0 ]]; then
      echo "Failed Stack Remediation:"
      echo "  • Review stack events for failure reasons"
      echo "  • Check IAM permissions for CloudFormation service role"
      echo "  • Verify resource limits and quotas"
      echo "  • Review template syntax and parameter values"
      echo "  • Delete and recreate if ROLLBACK_COMPLETE"
      echo "  • Use stack policy to prevent updates to critical resources"
      echo ""
    fi
    
    if [[ ${DRIFTED_STACKS} -gt 0 ]]; then
      echo "Drift Management:"
      echo "  • Review drifted resources and decide on action"
      echo "  • Option 1: Update template to match current state"
      echo "  • Option 2: Update stack to revert changes"
      echo "  • Implement change detection automation"
      echo "  • Use AWS Config rules for compliance"
      echo "  • Enable drift detection in CI/CD pipelines"
      echo "  • Schedule regular drift detection (weekly)"
      echo ""
    fi
    
    if [[ ${STALE_STACKS} -gt 0 ]]; then
      echo "Stale Stack Management:"
      echo "  • Review old stacks for continued relevance"
      echo "  • Delete unused stacks to reduce costs"
      echo "  • Update stacks to latest template versions"
      echo "  • Document stack ownership and purpose"
      echo "  • Use tags for lifecycle management"
      echo ""
    fi
    
    echo "Best Practices:"
    echo "  • Enable termination protection on production stacks"
    echo "  • Use stack policies to prevent resource updates"
    echo "  • Implement change sets for update previews"
    echo "  • Use nested stacks for modular infrastructure"
    echo "  • Tag stacks for cost allocation and organization"
    echo "  • Store templates in version control (Git)"
    echo "  • Use parameter files for environment-specific configs"
    echo "  • Enable rollback triggers for automated failure handling"
    echo "  • Document stack dependencies"
    echo ""
    
    echo "Security & Compliance:"
    echo "  • Use IAM service roles with least privilege"
    echo "  • Enable CloudTrail logging for stack operations"
    echo "  • Implement stack policy for critical resources"
    echo "  • Use AWS Secrets Manager/Parameter Store for secrets"
    echo "  • Enable AWS Config rules for compliance checks"
    echo "  • Review resource policies in templates"
    echo "  • Use cfn-nag or similar for template security scanning"
    echo ""
    
    echo "Monitoring & Alerting:"
    echo "  • Set up EventBridge rules for stack events"
    echo "  • Monitor stack status changes"
    echo "  • Alert on drift detection results"
    echo "  • Track failed resource creations"
    echo "  • Monitor nested stack failures"
    echo "  • Use CloudWatch Logs for troubleshooting"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • CloudFormation service is free (pay for resources)"
    echo "  • Delete unused stacks and their resources"
    echo "  • Review resource types for cost efficiency"
    echo "  • Use AWS Cost Explorer to track stack costs"
    echo "  • Implement auto-shutdown for dev/test stacks"
    echo "  • Tag resources for cost allocation"
    echo ""
    
    echo "Performance & Reliability:"
    echo "  • Use change sets to preview updates safely"
    echo "  • Implement rollback configuration for auto-recovery"
    echo "  • Test templates in dev before production"
    echo "  • Use stack outputs for cross-stack references"
    echo "  • Avoid circular dependencies between stacks"
    echo "  • Keep templates modular and reusable"
    echo "  • Use CloudFormation Registry for custom resources"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== CloudFormation Stack Monitor Started ==="
  
  write_header
  monitor_stacks
  monitor_stack_sets
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS CloudFormation Documentation:"
    echo "  https://docs.aws.amazon.com/cloudformation/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== CloudFormation Stack Monitor Completed ==="
  
  # Send alerts
  if [[ ${FAILED_STACKS} -gt 0 ]] || [[ ${DRIFTED_STACKS} -gt 0 ]]; then
    send_slack_alert "🚨 ${FAILED_STACKS} failed stacks, ${DRIFTED_STACKS} drifted stacks detected" "CRITICAL"
    send_email_alert "CloudFormation Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${STALE_STACKS} -gt 0 ]]; then
    send_slack_alert "⚠️ ${STALE_STACKS} stale CloudFormation stack(s) detected" "WARNING"
  fi
}

main "$@"

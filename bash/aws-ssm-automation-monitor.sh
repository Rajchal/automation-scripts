#!/bin/bash

################################################################################
# AWS Systems Manager Automation Monitor
# Monitors SSM patch compliance, session activity, automation executions,
# Parameter Store usage, State Manager associations, and provides remediation.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ssm-automation-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/ssm-automation.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
PATCH_COMPLIANCE_WARN="${PATCH_COMPLIANCE_WARN:-90}"      # % compliant
PARAMETER_AGE_WARN="${PARAMETER_AGE_WARN:-180}"           # days
MAX_ACTIVE_SESSIONS="${MAX_ACTIVE_SESSIONS:-50}"
AUTOMATION_FAILURE_WARN="${AUTOMATION_FAILURE_WARN:-5}"   # count
LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_INSTANCES=0
COMPLIANT_INSTANCES=0
NON_COMPLIANT_INSTANCES=0
FAILED_AUTOMATIONS=0
ACTIVE_SESSIONS=0
TOTAL_PARAMETERS=0

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
      "title": "Systems Manager Alert",
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
    echo "AWS Systems Manager Automation Monitor"
    echo "======================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_DAYS} days"
    echo ""
    echo "Thresholds:"
    echo "  Patch Compliance: ${PATCH_COMPLIANCE_WARN}%"
    echo "  Parameter Age: ${PARAMETER_AGE_WARN} days"
    echo "  Max Active Sessions: ${MAX_ACTIVE_SESSIONS}"
    echo "  Automation Failure Warning: ${AUTOMATION_FAILURE_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

check_patch_compliance() {
  log_message INFO "Checking patch compliance..."
  
  {
    echo "=== PATCH COMPLIANCE ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get instance compliance summary
  local compliance_json
  compliance_json=$(aws ssm describe-instance-patch-states \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"InstancePatchStates":[]}')
  
  local instances
  instances=$(echo "${compliance_json}" | jq -c '.InstancePatchStates[]' 2>/dev/null)
  
  if [[ -z "${instances}" ]]; then
    {
      echo "No patch state data available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r instance; do
    [[ -z "${instance}" ]] && continue
    
    local instance_id operation installed_count missing_count failed_count
    instance_id=$(echo "${instance}" | jq_safe '.InstanceId')
    operation=$(echo "${instance}" | jq_safe '.Operation')
    installed_count=$(echo "${instance}" | jq_safe '.InstalledCount')
    missing_count=$(echo "${instance}" | jq_safe '.MissingCount')
    failed_count=$(echo "${instance}" | jq_safe '.FailedCount')
    
    ((TOTAL_INSTANCES++))
    
    {
      echo "Instance: ${instance_id}"
      echo "  Operation: ${operation}"
      echo "  Installed Patches: ${installed_count}"
      echo "  Missing Patches: ${missing_count}"
      echo "  Failed Patches: ${failed_count}"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${missing_count} -eq 0 ]] && [[ ${failed_count} -eq 0 ]]; then
      ((COMPLIANT_INSTANCES++))
      {
        printf "  %b✓ Compliant%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      ((NON_COMPLIANT_INSTANCES++))
      {
        printf "  %b⚠️  Non-Compliant%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Instance ${instance_id} is non-compliant: ${missing_count} missing, ${failed_count} failed"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${instances}"
  
  # Calculate compliance percentage
  if [[ ${TOTAL_INSTANCES} -gt 0 ]]; then
    local compliance_pct
    compliance_pct=$(echo "scale=2; ${COMPLIANT_INSTANCES} * 100 / ${TOTAL_INSTANCES}" | bc -l)
    
    {
      echo "Compliance Summary:"
      echo "  Total Instances: ${TOTAL_INSTANCES}"
      echo "  Compliant: ${COMPLIANT_INSTANCES}"
      echo "  Non-Compliant: ${NON_COMPLIANT_INSTANCES}"
      echo "  Compliance Rate: ${compliance_pct}%"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${compliance_pct} < ${PATCH_COMPLIANCE_WARN}" | bc -l) )); then
      {
        printf "%b⚠️  Compliance below threshold (${PATCH_COMPLIANCE_WARN}%%)%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Patch compliance at ${compliance_pct}%, below ${PATCH_COMPLIANCE_WARN}%"
    fi
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_session_activity() {
  log_message INFO "Checking session activity..."
  
  {
    echo "=== SESSION MANAGER ACTIVITY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get active sessions
  local sessions_json
  sessions_json=$(aws ssm describe-sessions \
    --region "${REGION}" \
    --state Active \
    --output json 2>/dev/null || echo '{"Sessions":[]}')
  
  local session_count
  session_count=$(echo "${sessions_json}" | jq '.Sessions | length' 2>/dev/null || echo "0")
  
  ACTIVE_SESSIONS=${session_count}
  
  {
    echo "Active Sessions: ${session_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${session_count} -gt 0 ]]; then
    {
      echo ""
      echo "Session Details:"
    } >> "${OUTPUT_FILE}"
    
    local sessions
    sessions=$(echo "${sessions_json}" | jq -c '.Sessions[]' 2>/dev/null)
    
    while IFS= read -r session; do
      [[ -z "${session}" ]] && continue
      
      local session_id target owner start_date
      session_id=$(echo "${session}" | jq_safe '.SessionId')
      target=$(echo "${session}" | jq_safe '.Target')
      owner=$(echo "${session}" | jq_safe '.Owner')
      start_date=$(echo "${session}" | jq_safe '.StartDate')
      
      {
        echo "  Session: ${session_id}"
        echo "    Target: ${target}"
        echo "    Owner: ${owner}"
        echo "    Started: ${start_date}"
        echo ""
      } >> "${OUTPUT_FILE}"
      
    done <<< "${sessions}"
  fi
  
  if [[ ${session_count} -gt ${MAX_ACTIVE_SESSIONS} ]]; then
    {
      printf "%b⚠️  High number of active sessions detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Active sessions (${session_count}) exceed threshold (${MAX_ACTIVE_SESSIONS})"
  else
    {
      echo "✓ Session count within limits"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_automation_executions() {
  log_message INFO "Checking automation executions..."
  
  {
    echo "=== AUTOMATION EXECUTIONS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get recent automation executions
  local max_results=50
  local executions_json
  executions_json=$(aws ssm describe-automation-executions \
    --region "${REGION}" \
    --max-results ${max_results} \
    --output json 2>/dev/null || echo '{"AutomationExecutionMetadataList":[]}')
  
  local execution_count
  execution_count=$(echo "${executions_json}" | jq '.AutomationExecutionMetadataList | length' 2>/dev/null || echo "0")
  
  if [[ ${execution_count} -eq 0 ]]; then
    {
      echo "No recent automation executions found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Recent Executions (last ${max_results}):"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local executions
  executions=$(echo "${executions_json}" | jq -c '.AutomationExecutionMetadataList[]' 2>/dev/null)
  
  local success_count=0
  local failed_count=0
  local in_progress_count=0
  local cancelled_count=0
  
  while IFS= read -r execution; do
    [[ -z "${execution}" ]] && continue
    
    local exec_id document_name exec_status start_time
    exec_id=$(echo "${execution}" | jq_safe '.AutomationExecutionId')
    document_name=$(echo "${execution}" | jq_safe '.DocumentName')
    exec_status=$(echo "${execution}" | jq_safe '.AutomationExecutionStatus')
    start_time=$(echo "${execution}" | jq_safe '.ExecutionStartTime')
    
    case "${exec_status}" in
      Success)
        ((success_count++))
        ;;
      Failed|TimedOut)
        ((failed_count++))
        ((FAILED_AUTOMATIONS++))
        {
          echo "  Execution: ${exec_id}"
          echo "    Document: ${document_name}"
          printf "    Status: %b%s%b\n" "${RED}" "${exec_status}" "${NC}"
          echo "    Started: ${start_time}"
          echo ""
        } >> "${OUTPUT_FILE}"
        log_message ERROR "Automation ${exec_id} failed: ${document_name}"
        ;;
      InProgress|Pending|Waiting)
        ((in_progress_count++))
        ;;
      Cancelled)
        ((cancelled_count++))
        ;;
    esac
    
  done <<< "${executions}"
  
  {
    echo "Execution Summary:"
    echo "  Total Recent: ${execution_count}"
    echo "  Success: ${success_count}"
    echo "  Failed/TimedOut: ${failed_count}"
    echo "  In Progress: ${in_progress_count}"
    echo "  Cancelled: ${cancelled_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${failed_count} -gt ${AUTOMATION_FAILURE_WARN} ]]; then
    {
      printf "%b⚠️  High automation failure rate detected%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Automation failures (${failed_count}) exceed threshold (${AUTOMATION_FAILURE_WARN})"
  else
    {
      echo "✓ Automation failure rate acceptable"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_parameter_store() {
  log_message INFO "Checking Parameter Store..."
  
  {
    echo "=== PARAMETER STORE ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get parameters
  local params_json
  params_json=$(aws ssm describe-parameters \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"Parameters":[]}')
  
  local param_count
  param_count=$(echo "${params_json}" | jq '.Parameters | length' 2>/dev/null || echo "0")
  
  TOTAL_PARAMETERS=${param_count}
  
  {
    echo "Total Parameters: ${param_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${param_count} -eq 0 ]]; then
    return
  fi
  
  local params
  params=$(echo "${params_json}" | jq -c '.Parameters[]' 2>/dev/null)
  
  local old_params=0
  local secure_count=0
  local standard_count=0
  
  while IFS= read -r param; do
    [[ -z "${param}" ]] && continue
    
    local name param_type last_modified tier
    name=$(echo "${param}" | jq_safe '.Name')
    param_type=$(echo "${param}" | jq_safe '.Type')
    last_modified=$(echo "${param}" | jq_safe '.LastModifiedDate')
    tier=$(echo "${param}" | jq_safe '.Tier')
    
    case "${param_type}" in
      SecureString) ((secure_count++)) ;;
      String|StringList) ((standard_count++)) ;;
    esac
    
    # Check age
    if [[ -n "${last_modified}" ]]; then
      local modified_epoch
      modified_epoch=$(date -d "${last_modified}" +%s 2>/dev/null || echo "0")
      local current_epoch
      current_epoch=$(date +%s)
      local age_days
      age_days=$(( (current_epoch - modified_epoch) / 86400 ))
      
      if [[ ${age_days} -gt ${PARAMETER_AGE_WARN} ]]; then
        ((old_params++))
        {
          echo "Old Parameter:"
          echo "  Name: ${name}"
          echo "  Type: ${param_type}"
          echo "  Age: ${age_days} days"
          printf "  %b⚠️  Not updated in ${PARAMETER_AGE_WARN}+ days%b\n" "${YELLOW}" "${NC}"
          echo ""
        } >> "${OUTPUT_FILE}"
      fi
    fi
    
  done <<< "${params}"
  
  {
    echo "Parameter Type Breakdown:"
    echo "  SecureString: ${secure_count}"
    echo "  String/StringList: ${standard_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${old_params} -gt 0 ]]; then
    {
      printf "%b⚠️  %d parameter(s) not updated in %d+ days%b\n" "${YELLOW}" "${old_params}" "${PARAMETER_AGE_WARN}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "${old_params} parameters older than ${PARAMETER_AGE_WARN} days"
  else
    {
      echo "✓ All parameters recently updated"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_state_manager() {
  log_message INFO "Checking State Manager associations..."
  
  {
    echo "=== STATE MANAGER ASSOCIATIONS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get associations
  local assoc_json
  assoc_json=$(aws ssm list-associations \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"Associations":[]}')
  
  local assoc_count
  assoc_count=$(echo "${assoc_json}" | jq '.Associations | length' 2>/dev/null || echo "0")
  
  {
    echo "Total Associations: ${assoc_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${assoc_count} -eq 0 ]]; then
    return
  fi
  
  local associations
  associations=$(echo "${assoc_json}" | jq -c '.Associations[]' 2>/dev/null)
  
  local success_count=0
  local failed_count=0
  
  while IFS= read -r assoc; do
    [[ -z "${assoc}" ]] && continue
    
    local assoc_id assoc_name document_name last_execution
    assoc_id=$(echo "${assoc}" | jq_safe '.AssociationId')
    assoc_name=$(echo "${assoc}" | jq_safe '.AssociationName')
    document_name=$(echo "${assoc}" | jq_safe '.Name')
    last_execution=$(echo "${assoc}" | jq_safe '.LastExecutionDate')
    
    # Get association status
    local status_json
    status_json=$(aws ssm describe-association \
      --association-id "${assoc_id}" \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{}')
    
    local status
    status=$(echo "${status_json}" | jq_safe '.AssociationDescription.Status.Name')
    
    {
      echo "Association: ${assoc_name:-${assoc_id}}"
      echo "  Document: ${document_name}"
      echo "  Last Execution: ${last_execution}"
      echo "  Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    case "${status}" in
      Success)
        ((success_count++))
        {
          printf "  %b✓ Successful%b\n" "${GREEN}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ;;
      Failed)
        ((failed_count++))
        {
          printf "  %b❌ Failed%b\n" "${RED}" "${NC}"
        } >> "${OUTPUT_FILE}"
        log_message ERROR "Association ${assoc_name:-${assoc_id}} failed"
        ;;
      *)
        {
          echo "  Status: ${status}"
        } >> "${OUTPUT_FILE}"
        ;;
    esac
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${associations}"
  
  {
    echo "Association Summary:"
    echo "  Total: ${assoc_count}"
    echo "  Success: ${success_count}"
    echo "  Failed: ${failed_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${failed_count} -gt 0 ]]; then
    log_message WARN "${failed_count} State Manager associations failed"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_managed_instances() {
  log_message INFO "Checking managed instances..."
  
  {
    echo "=== MANAGED INSTANCES ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Get instance information
  local instances_json
  instances_json=$(aws ssm describe-instance-information \
    --region "${REGION}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{"InstanceInformationList":[]}')
  
  local instance_count
  instance_count=$(echo "${instances_json}" | jq '.InstanceInformationList | length' 2>/dev/null || echo "0")
  
  {
    echo "Total Managed Instances: ${instance_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${instance_count} -eq 0 ]]; then
    return
  fi
  
  local instances
  instances=$(echo "${instances_json}" | jq -c '.InstanceInformationList[]' 2>/dev/null)
  
  local online_count=0
  local offline_count=0
  
  while IFS= read -r instance; do
    [[ -z "${instance}" ]] && continue
    
    local instance_id ping_status agent_version platform
    instance_id=$(echo "${instance}" | jq_safe '.InstanceId')
    ping_status=$(echo "${instance}" | jq_safe '.PingStatus')
    agent_version=$(echo "${instance}" | jq_safe '.AgentVersion')
    platform=$(echo "${instance}" | jq_safe '.PlatformType')
    
    case "${ping_status}" in
      Online)
        ((online_count++))
        ;;
      ConnectionLost|Inactive)
        ((offline_count++))
        {
          echo "Offline Instance:"
          echo "  ID: ${instance_id}"
          echo "  Platform: ${platform}"
          echo "  Agent: ${agent_version}"
          printf "  Status: %b%s%b\n" "${RED}" "${ping_status}" "${NC}"
          echo ""
        } >> "${OUTPUT_FILE}"
        log_message WARN "Instance ${instance_id} is ${ping_status}"
        ;;
    esac
    
  done <<< "${instances}"
  
  {
    echo "Instance Status Summary:"
    echo "  Online: ${online_count}"
    echo "  Offline/ConnectionLost: ${offline_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${offline_count} -gt 0 ]]; then
    {
      printf "%b⚠️  %d instance(s) offline or connection lost%b\n" "${YELLOW}" "${offline_count}" "${NC}"
    } >> "${OUTPUT_FILE}"
  else
    {
      echo "✓ All managed instances online"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== SYSTEMS MANAGER SUMMARY ==="
    echo ""
    echo "Patch Compliance:"
    printf "  Compliant: %d / %d\n" "${COMPLIANT_INSTANCES}" "${TOTAL_INSTANCES}"
    echo ""
    echo "Session Activity:"
    printf "  Active Sessions: %d\n" "${ACTIVE_SESSIONS}"
    echo ""
    echo "Automation:"
    printf "  Failed Executions: %d\n" "${FAILED_AUTOMATIONS}"
    echo ""
    echo "Parameter Store:"
    printf "  Total Parameters: %d\n" "${TOTAL_PARAMETERS}"
    echo ""
    
    if [[ ${NON_COMPLIANT_INSTANCES} -gt 0 ]] || [[ ${FAILED_AUTOMATIONS} -gt ${AUTOMATION_FAILURE_WARN} ]]; then
      printf "%b[WARNING] Issues detected in Systems Manager%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Systems Manager operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

remediation_guide() {
  {
    echo "=== REMEDIATION & BEST PRACTICES ==="
    echo ""
    
    if [[ ${NON_COMPLIANT_INSTANCES} -gt 0 ]]; then
      echo "Patch Compliance Remediation:"
      echo "  1. Review missing patches on non-compliant instances"
      echo "  2. Create maintenance window for patching"
      echo "  3. Use AWS-RunPatchBaseline document for manual patching"
      echo "  4. Configure State Manager for automated patching"
      echo "  5. Set up SNS notifications for patch failures"
      echo ""
    fi
    
    if [[ ${FAILED_AUTOMATIONS} -gt 0 ]]; then
      echo "Automation Failure Resolution:"
      echo "  1. Review automation execution logs in CloudWatch"
      echo "  2. Verify IAM role permissions for automation"
      echo "  3. Check document syntax and parameter validation"
      echo "  4. Implement error handling in custom documents"
      echo "  5. Use dry-run mode for testing changes"
      echo ""
    fi
    
    echo "Best Practices:"
    echo "  • Enable Session Manager logging to S3/CloudWatch Logs"
    echo "  • Rotate Parameter Store SecureString values regularly"
    echo "  • Use resource groups for targeted automation"
    echo "  • Implement tagging strategy for instance targeting"
    echo "  • Schedule maintenance windows during off-peak hours"
    echo "  • Monitor SSM Agent health and version compliance"
    echo "  • Use OpsCenter for centralized operations management"
    echo "  • Implement CloudWatch alarms for compliance metrics"
    echo "  • Document runbook procedures in Systems Manager Documents"
    echo "  • Use Change Calendar to prevent changes during freeze periods"
    echo ""
    echo "Security Recommendations:"
    echo "  • Restrict Session Manager access with IAM conditions"
    echo "  • Enable KMS encryption for Parameter Store"
    echo "  • Audit parameter access with CloudTrail"
    echo "  • Use VPC endpoints for Systems Manager in private subnets"
    echo "  • Implement least-privilege automation role policies"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Systems Manager Automation Monitor Started ==="
  
  write_header
  check_patch_compliance
  check_session_activity
  check_automation_executions
  check_parameter_store
  check_state_manager
  check_managed_instances
  generate_summary
  remediation_guide
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Systems Manager Documentation:"
    echo "  https://docs.aws.amazon.com/systems-manager/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Systems Manager Automation Monitor Completed ==="
  
  # Send alerts
  if [[ ${NON_COMPLIANT_INSTANCES} -gt 0 ]] || [[ ${FAILED_AUTOMATIONS} -gt ${AUTOMATION_FAILURE_WARN} ]]; then
    send_slack_alert "⚠️ Systems Manager issues: ${NON_COMPLIANT_INSTANCES} non-compliant instances, ${FAILED_AUTOMATIONS} failed automations" "WARNING"
    send_email_alert "Systems Manager Alert" "$(cat "${OUTPUT_FILE}")"
  fi
}

main "$@"

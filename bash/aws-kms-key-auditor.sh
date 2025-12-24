#!/bin/bash

################################################################################
# AWS KMS Key Auditor
# Audits KMS keys for rotation status, policy risks, unused keys, pending
# deletion, and provides security recommendations and compliance insights.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/kms-key-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/kms-key-audit.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
ROTATION_AGE_WARN_DAYS="${ROTATION_AGE_WARN_DAYS:-90}"  # Warn if key not rotated in 90 days
PENDING_DELETE_WARN_DAYS="${PENDING_DELETE_WARN_DAYS:-7}" # Warn if key pending deletion soon
KEY_UNUSED_WARN_DAYS="${KEY_UNUSED_WARN_DAYS:-180}"     # Warn if key unused for 6 months
LOOKBACK_DAYS="${LOOKBACK_DAYS:-30}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_KEYS=0
KEYS_NOT_ROTATED=0
KEYS_PENDING_DELETION=0
KEYS_UNUSED=0
POLICY_RISKS=0
CMK_KEYS=0
AWS_MANAGED_KEYS=0
KEY_ALIASES=0

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
      "title": "KMS Key Alert",
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
    echo "AWS KMS Key Auditor"
    echo "==================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
    echo "Thresholds:"
    echo "  Rotation Age Warning: ${ROTATION_AGE_WARN_DAYS} days"
    echo "  Pending Delete Warning: ${PENDING_DELETE_WARN_DAYS} days"
    echo "  Unused Key Warning: ${KEY_UNUSED_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_keys() {
  aws kms list-keys \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Keys":[]}'
}

describe_key() {
  local key_id="$1"
  aws kms describe-key \
    --key-id "${key_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_key_rotation_status() {
  local key_id="$1"
  aws kms get-key-rotation-status \
    --key-id "${key_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"KeyRotationEnabled":false}'
}

get_key_policy() {
  local key_id="$1"
  aws kms get-key-policy \
    --key-id "${key_id}" \
    --policy-name default \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_key_aliases() {
  aws kms list-aliases \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Aliases":[]}'
}

list_grants() {
  local key_id="$1"
  aws kms list-grants \
    --key-id "${key_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Grants":[]}'
}

get_cloudwatch_metrics() {
  local key_id="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_DAYS} days ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/KMS \
    --metric-name "${metric_name}" \
    --dimensions Name=KeyId,Value="${key_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 86400 \
    --statistics Sum,Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

audit_keys() {
  log_message INFO "Starting KMS key audit"
  
  {
    echo "=== KMS KEY INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local keys_json
  keys_json=$(list_keys)
  
  local key_count
  key_count=$(echo "${keys_json}" | jq '.Keys | length' 2>/dev/null || echo "0")
  
  TOTAL_KEYS=${key_count}
  
  if [[ ${key_count} -eq 0 ]]; then
    {
      echo "No KMS keys found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Keys: ${key_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local keys
  keys=$(echo "${keys_json}" | jq -r '.Keys[].KeyId' 2>/dev/null)
  
  while IFS= read -r key_id; do
    [[ -z "${key_id}" ]] && continue
    
    log_message INFO "Analyzing key: ${key_id}"
    
    analyze_key "${key_id}"
    
  done <<< "${keys}"
  
  audit_key_aliases
}

analyze_key() {
  local key_id="$1"
  
  local key_detail
  key_detail=$(describe_key "${key_id}")
  
  local key_arn key_state key_manager creation_date
  key_arn=$(echo "${key_detail}" | jq_safe '.KeyMetadata.Arn')
  key_state=$(echo "${key_detail}" | jq_safe '.KeyMetadata.KeyState')
  key_manager=$(echo "${key_detail}" | jq_safe '.KeyMetadata.KeyManager')
  creation_date=$(echo "${key_detail}" | jq_safe '.KeyMetadata.CreationDate')
  
  # Track key type
  if [[ "${key_manager}" == "CUSTOMER" ]]; then
    ((CMK_KEYS++))
  else
    ((AWS_MANAGED_KEYS++))
  fi
  
  {
    echo "=== KEY: ${key_id} ==="
    echo ""
    echo "ARN: ${key_arn}"
    echo "Type: ${key_manager}"
    echo "State: ${key_state}"
    echo "Created: ${creation_date}"
  } >> "${OUTPUT_FILE}"
  
  # Skip AWS managed keys for some checks (not user-manageable)
  if [[ "${key_manager}" != "CUSTOMER" ]]; then
    {
      echo "Note: AWS-managed key - limited audit scope"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Check rotation status
  check_rotation_status "${key_id}"
  
  # Check for pending deletion
  check_pending_deletion "${key_detail}" "${key_id}"
  
  # Check key usage
  check_key_usage "${key_id}"
  
  # Check key policy
  audit_key_policy "${key_id}"
  
  # Check grants
  check_grants "${key_id}"
  
  {
    echo "---"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_rotation_status() {
  local key_id="$1"
  
  {
    echo "Rotation Status:"
  } >> "${OUTPUT_FILE}"
  
  local rotation_json
  rotation_json=$(get_key_rotation_status "${key_id}")
  
  local rotation_enabled
  rotation_enabled=$(echo "${rotation_json}" | jq_safe '.KeyRotationEnabled')
  
  {
    echo "  Enabled: ${rotation_enabled}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${rotation_enabled}" == "false" ]]; then
    ((KEYS_NOT_ROTATED++))
    {
      printf "  %b⚠️  Key rotation is disabled%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Key ${key_id} has rotation disabled"
  else
    {
      printf "  %b✓ Key rotation enabled%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_pending_deletion() {
  local key_detail="$1"
  local key_id="$2"
  
  local pending_deletion_date
  pending_deletion_date=$(echo "${key_detail}" | jq_safe '.KeyMetadata.PendingDeletionWindowInDays // ""')
  
  if [[ -n "${pending_deletion_date}" && "${pending_deletion_date}" != "null" ]]; then
    ((KEYS_PENDING_DELETION++))
    {
      echo "Deletion Status:"
      printf "  %b⚠️  PENDING DELETION in %s days%b\n" "${RED}" "${pending_deletion_date}" "${NC}"
      echo ""
    } >> "${OUTPUT_FILE}"
    log_message WARN "Key ${key_id} pending deletion in ${pending_deletion_date} days"
  fi
}

check_key_usage() {
  local key_id="$1"
  
  {
    echo "Key Usage Metrics (Last ${LOOKBACK_DAYS} days):"
  } >> "${OUTPUT_FILE}"
  
  # Get CloudWatch metrics for key usage
  local user_error_count
  user_error_count=$(get_cloudwatch_metrics "${key_id}" "UserErrorCount" | jq '.Datapoints | length' 2>/dev/null || echo "0")
  
  local throttled_count
  throttled_count=$(get_cloudwatch_metrics "${key_id}" "ThrottledCount" | jq '.Datapoints | length' 2>/dev/null || echo "0")
  
  # Check if key has been used recently (look for any metrics)
  local usage_json
  usage_json=$(get_cloudwatch_metrics "${key_id}" "UserErrorCount")
  
  local datapoint_count
  datapoint_count=$(echo "${usage_json}" | jq '.Datapoints | length' 2>/dev/null || echo "0")
  
  if [[ ${datapoint_count} -eq 0 ]]; then
    ((KEYS_UNUSED++))
    {
      printf "  %b⚠️  No usage in the last ${LOOKBACK_DAYS} days%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Key ${key_id} has not been used recently"
  else
    {
      printf "  %b✓ Key is actively used%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo "  User Errors: ${user_error_count} datapoints"
    echo "  Throttled Requests: ${throttled_count} datapoints"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_key_policy() {
  local key_id="$1"
  
  {
    echo "Key Policy:"
  } >> "${OUTPUT_FILE}"
  
  local policy_json
  policy_json=$(get_key_policy "${key_id}")
  
  local policy
  policy=$(echo "${policy_json}" | jq_safe '.Policy')
  
  if [[ -z "${policy}" || "${policy}" == "null" ]]; then
    {
      echo "  Unable to retrieve policy"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Parse policy as JSON
  local policy_obj
  policy_obj=$(echo "${policy}" | jq '.' 2>/dev/null)
  
  if [[ -z "${policy_obj}" ]]; then
    {
      echo "  Invalid policy format"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Check for wildcard principals
  local principal_count
  principal_count=$(echo "${policy_obj}" | jq '[.. | .Principal? | select(. != null) | if type == "string" then select(. == "*") else select(.AWS[]? == "*") end] | length' 2>/dev/null || echo "0")
  
  if [[ ${principal_count} -gt 0 ]]; then
    ((POLICY_RISKS++))
    {
      printf "  %b⚠️  Wildcard principal detected%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Key ${key_id} policy contains wildcard principal"
  fi
  
  # Check for overly permissive actions
  local deny_count
  deny_count=$(echo "${policy_obj}" | jq '[.. | .Effect? | select(. == "Deny")] | length' 2>/dev/null || echo "0")
  
  if [[ ${deny_count} -eq 0 ]]; then
    {
      printf "  %b⚠️  No Deny statements found%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  else
    {
      printf "  %b✓ Policy contains Deny statements%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_grants() {
  local key_id="$1"
  
  {
    echo "Grants:"
  } >> "${OUTPUT_FILE}"
  
  local grants_json
  grants_json=$(list_grants "${key_id}")
  
  local grant_count
  grant_count=$(echo "${grants_json}" | jq '.Grants | length' 2>/dev/null || echo "0")
  
  {
    echo "  Total Grants: ${grant_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${grant_count} -gt 0 ]]; then
    {
      echo "  Granted to:"
    } >> "${OUTPUT_FILE}"
    
    local grants
    grants=$(echo "${grants_json}" | jq -c '.Grants[]' 2>/dev/null)
    
    while IFS= read -r grant; do
      [[ -z "${grant}" ]] && continue
      
      local grantee_principal operations
      grantee_principal=$(echo "${grant}" | jq_safe '.GranteePrincipal')
      operations=$(echo "${grant}" | jq -r '.Operations[]' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      
      {
        echo "    - Principal: ${grantee_principal}"
        echo "      Operations: ${operations}"
      } >> "${OUTPUT_FILE}"
      
    done <<< "${grants}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_key_aliases() {
  log_message INFO "Auditing key aliases"
  
  {
    echo "=== KEY ALIASES ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local aliases_json
  aliases_json=$(list_key_aliases)
  
  local alias_count
  alias_count=$(echo "${aliases_json}" | jq '.Aliases | length' 2>/dev/null || echo "0")
  
  KEY_ALIASES=${alias_count}
  
  {
    echo "Total Aliases: ${alias_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${alias_count} -eq 0 ]]; then
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local aliases
  aliases=$(echo "${aliases_json}" | jq -c '.Aliases[] | select(.TargetKeyId != null)' 2>/dev/null)
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r alias; do
    [[ -z "${alias}" ]] && continue
    
    local alias_name target_key_id
    alias_name=$(echo "${alias}" | jq_safe '.AliasName')
    target_key_id=$(echo "${alias}" | jq_safe '.TargetKeyId')
    
    {
      echo "Alias: ${alias_name}"
      echo "  Target Key ID: ${target_key_id}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${aliases}"
}

generate_summary() {
  {
    echo ""
    echo "=== KMS KEY AUDIT SUMMARY ==="
    echo ""
    printf "Total Keys: %d\n" "${TOTAL_KEYS}"
    printf "Customer Managed Keys (CMK): %d\n" "${CMK_KEYS}"
    printf "AWS Managed Keys: %d\n" "${AWS_MANAGED_KEYS}"
    printf "Key Aliases: %d\n" "${KEY_ALIASES}"
    echo ""
    printf "Keys with Rotation Disabled: %d\n" "${KEYS_NOT_ROTATED}"
    printf "Keys Pending Deletion: %d\n" "${KEYS_PENDING_DELETION}"
    printf "Unused Keys (${LOOKBACK_DAYS}d): %d\n" "${KEYS_UNUSED}"
    printf "Keys with Policy Risks: %d\n" "${POLICY_RISKS}"
    echo ""
    
    if [[ ${KEYS_PENDING_DELETION} -gt 0 ]] || [[ ${POLICY_RISKS} -gt 0 ]]; then
      printf "%b[CRITICAL] KMS key security issues detected%b\n" "${RED}" "${NC}"
    elif [[ ${KEYS_NOT_ROTATED} -gt 0 ]] || [[ ${KEYS_UNUSED} -gt 0 ]]; then
      printf "%b[WARNING] KMS compliance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All KMS keys properly configured%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${POLICY_RISKS} -gt 0 ]]; then
      echo "Policy Security Fixes:"
      echo "  • Remove wildcard (*) principals from policies"
      echo "  • Use specific ARNs for principals instead"
      echo "  • Implement least privilege principle"
      echo "  • Use condition statements to restrict scope"
      echo "  • Add Deny statements for non-compliant actions"
      echo "  • Review and audit all key policies quarterly"
      echo "  • Use AWS access analyzer for policy validation"
      echo ""
    fi
    
    if [[ ${KEYS_NOT_ROTATED} -gt 0 ]]; then
      echo "Key Rotation Enablement:"
      echo "  • Enable automatic key rotation for all CMKs"
      echo "  • AWS KMS rotates keys annually automatically"
      echo "  • Rotation does not affect key ID or aliases"
      echo "  • Consider manual rotation for compliance needs"
      echo "  • Document rotation policy for audit trails"
      echo "  • Test rotation procedures in non-prod first"
      echo ""
    fi
    
    if [[ ${KEYS_PENDING_DELETION} -gt 0 ]]; then
      echo "Pending Deletion Management:"
      echo "  • Review usage of keys pending deletion"
      echo "  • Migrate workloads to new keys if needed"
      echo "  • Cancel deletion if key is still required"
      echo "  • Establish key lifecycle policy"
      echo "  • Document reason for key deletion"
      echo "  • Ensure backups don't depend on deleted keys"
      echo ""
    fi
    
    if [[ ${KEYS_UNUSED} -gt 0 ]]; then
      echo "Unused Key Management:"
      echo "  • Verify if unused keys are truly unused"
      echo "  • Consider deleting unused keys (schedule deletion)"
      echo "  • Archive keys not needed for current workloads"
      echo "  • Set up CloudWatch alarms on key usage"
      echo "  • Use AWS Config rules for key lifecycle"
      echo "  • Review CloudTrail logs for historical usage"
      echo ""
    fi
    
    echo "Cryptography Best Practices:"
    echo "  • Use customer-managed keys (CMK) for sensitive data"
    echo "  • Enable automatic key rotation annually"
    echo "  • Use separate keys for different services"
    echo "  • Implement key aliasing for application readability"
    echo "  • Use envelope encryption for large data"
    echo "  • Use grants for fine-grained permission control"
    echo "  • Implement multi-region keys for disaster recovery"
    echo "  • Use asymmetric keys for signing/verification"
    echo ""
    
    echo "Security Hardening:"
    echo "  • Use IAM roles with least privilege"
    echo "  • Enable CloudTrail logging for KMS API calls"
    echo "  • Implement resource-based key policies"
    echo "  • Use VPC endpoints for private KMS access"
    echo "  • Enable MFA delete on key deletion"
    echo "  • Audit key policies for compliance"
    echo "  • Use AWS Config rules for compliance tracking"
    echo "  • Implement cross-account key access carefully"
    echo ""
    
    echo "Monitoring & Alerting:"
    echo "  • Set CloudWatch alarms on key usage anomalies"
    echo "  • Monitor UserErrorCount for permission issues"
    echo "  • Track ThrottledCount for scaling needs"
    echo "  • Alert on pending key deletion"
    echo "  • Monitor key policy changes via CloudTrail"
    echo "  • Use EventBridge for KMS event notifications"
    echo "  • Log failed decrypt operations"
    echo "  • Implement anomaly detection on key usage"
    echo ""
    
    echo "Compliance & Governance:"
    echo "  • Document key usage and ownership"
    echo "  • Implement key tagging strategy"
    echo "  • Establish key rotation schedule"
    echo "  • Create disaster recovery procedures"
    echo "  • Audit key access quarterly"
    echo "  • Maintain key audit logs (CloudTrail)"
    echo "  • Comply with regulatory requirements (HIPAA, PCI)"
    echo "  • Implement change approval process for policies"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • AWS managed keys are free"
    echo "  • CMK pricing: \$1.00/month per key"
    echo "  • API requests: \$0.03 per 10K requests"
    echo "  • Delete unused keys to reduce costs"
    echo "  • Use AWS managed keys for standard services"
    echo "  • Consolidate workloads to fewer keys"
    echo "  • Monitor key usage to optimize allocation"
    echo ""
    
    echo "Integration Points:"
    echo "  • Integrate with AWS Secrets Manager"
    echo "  • Use with S3 for SSE-KMS encryption"
    echo "  • RDS/EBS automated encryption"
    echo "  • DynamoDB encryption at rest"
    echo "  • Lambda environment variable encryption"
    echo "  • CloudWatch Logs encryption"
    echo "  • SNS/SQS message encryption"
    echo "  • EBS snapshot encryption"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== KMS Key Auditor Started ==="
  
  write_header
  audit_keys
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS KMS Documentation:"
    echo "  https://docs.aws.amazon.com/kms/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== KMS Key Auditor Completed ==="
  
  # Send alerts
  if [[ ${KEYS_PENDING_DELETION} -gt 0 ]] || [[ ${POLICY_RISKS} -gt 0 ]]; then
    send_slack_alert "🚨 KMS security issues: ${KEYS_PENDING_DELETION} keys pending deletion, ${POLICY_RISKS} policy risks" "CRITICAL"
    send_email_alert "KMS Key Audit Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${KEYS_NOT_ROTATED} -gt 0 ]] || [[ ${KEYS_UNUSED} -gt 0 ]]; then
    send_slack_alert "⚠️ ${KEYS_NOT_ROTATED} KMS key(s) without rotation, ${KEYS_UNUSED} unused key(s)" "WARNING"
  fi
}

main "$@"

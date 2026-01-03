#!/bin/bash

################################################################################
# AWS IAM Security Auditor
# Audits IAM users, roles, policies for security issues and unused credentials
################################################################################

set -euo pipefail

# Configuration
OUTPUT_FILE="/tmp/iam-security-audit-$(date +%s).txt"
LOG_FILE="/var/log/iam-security-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
PASSWORD_AGE_WARN_DAYS="${PASSWORD_AGE_WARN_DAYS:-90}"
ACCESS_KEY_AGE_WARN_DAYS="${ACCESS_KEY_AGE_WARN_DAYS:-90}"
UNUSED_CREDENTIAL_DAYS="${UNUSED_CREDENTIAL_DAYS:-90}"

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

# API wrappers
get_credential_report() {
  # Generate report first
  aws iam generate-credential-report >/dev/null 2>&1 || true
  sleep 2
  aws iam get-credential-report \
    --output json 2>/dev/null | jq_safe '.Content' | base64 -d || true
}

list_users() {
  aws iam list-users \
    --output json 2>/dev/null || echo '{}'
}

list_roles() {
  aws iam list-roles \
    --output json 2>/dev/null || echo '{}'
}

list_policies() {
  aws iam list-policies \
    --scope Local \
    --output json 2>/dev/null || echo '{}'
}

get_account_summary() {
  aws iam get-account-summary \
    --output json 2>/dev/null || echo '{}'
}

list_mfa_devices() {
  local user="$1"
  aws iam list-mfa-devices \
    --user-name "${user}" \
    --output json 2>/dev/null || echo '{}'
}

get_policy_version() {
  local policy_arn="$1"; local version_id="$2"
  aws iam get-policy-version \
    --policy-arn "${policy_arn}" \
    --version-id "${version_id}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS IAM Security Audit Report"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Password Age Warn: ${PASSWORD_AGE_WARN_DAYS} days"
    echo "Access Key Age Warn: ${ACCESS_KEY_AGE_WARN_DAYS} days"
    echo "Unused Credential: ${UNUSED_CREDENTIAL_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_account_summary() {
  log_message INFO "Getting IAM account summary"
  {
    echo "=== ACCOUNT SUMMARY ==="
  } >> "${OUTPUT_FILE}"

  local summary
  summary=$(get_account_summary)

  local users groups roles policies mfa_devices
  users=$(echo "${summary}" | jq_safe '.SummaryMap.Users')
  groups=$(echo "${summary}" | jq_safe '.SummaryMap.Groups')
  roles=$(echo "${summary}" | jq_safe '.SummaryMap.Roles')
  policies=$(echo "${summary}" | jq_safe '.SummaryMap.Policies')
  mfa_devices=$(echo "${summary}" | jq_safe '.SummaryMap.MFADevices')

  {
    echo "IAM Users: ${users}"
    echo "IAM Groups: ${groups}"
    echo "IAM Roles: ${roles}"
    echo "Customer Managed Policies: ${policies}"
    echo "MFA Devices: ${mfa_devices}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_credential_report() {
  log_message INFO "Auditing user credentials"
  {
    echo "=== USER CREDENTIAL AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local old_passwords=0 old_access_keys=0 unused_credentials=0 no_mfa=0 root_access_keys=0

  local report
  report=$(get_credential_report)

  echo "${report}" | tail -n +2 | while IFS=, read -r user arn created password_enabled password_last_used password_last_changed password_next_rotation mfa_active access_key1_active access_key1_last_rotated access_key1_last_used access_key2_active access_key2_last_rotated access_key2_last_used cert1_active cert1_last_rotated cert2_active cert2_last_rotated; do
    {
      echo "User: ${user}"
      echo "  ARN: ${arn}"
      echo "  Created: ${created}"
    } >> "${OUTPUT_FILE}"

    # Root user check
    if [[ "${user}" == "<root_account>" ]]; then
      if [[ "${access_key1_active}" == "true" || "${access_key2_active}" == "true" ]]; then
        ((root_access_keys++))
        echo "  WARNING: Root account has active access keys" >> "${OUTPUT_FILE}"
      fi
      if [[ "${mfa_active}" != "true" ]]; then
        echo "  WARNING: Root account MFA not enabled" >> "${OUTPUT_FILE}"
      fi
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    # Password checks
    if [[ "${password_enabled}" == "true" ]]; then
      echo "  Password: enabled" >> "${OUTPUT_FILE}"
      
      if [[ "${mfa_active}" != "true" ]]; then
        ((no_mfa++))
        echo "  WARNING: MFA not enabled" >> "${OUTPUT_FILE}"
      fi

      if [[ -n "${password_last_changed}" && "${password_last_changed}" != "N/A" && "${password_last_changed}" != "no_information" ]]; then
        local password_age
        local changed_epoch now_epoch
        changed_epoch=$(date -d "${password_last_changed}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        password_age=$(( (now_epoch - changed_epoch) / 86400 ))
        
        echo "  Password Age: ${password_age} days" >> "${OUTPUT_FILE}"
        
        if (( password_age >= PASSWORD_AGE_WARN_DAYS )); then
          ((old_passwords++))
          echo "  WARNING: Password older than ${PASSWORD_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
        fi
      fi

      # Check for unused password
      if [[ -n "${password_last_used}" && "${password_last_used}" != "N/A" && "${password_last_used}" != "no_information" ]]; then
        local last_used_epoch now_epoch unused_days
        last_used_epoch=$(date -d "${password_last_used}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        unused_days=$(( (now_epoch - last_used_epoch) / 86400 ))
        
        if (( unused_days >= UNUSED_CREDENTIAL_DAYS )); then
          ((unused_credentials++))
          echo "  WARNING: Password not used in ${unused_days} days" >> "${OUTPUT_FILE}"
        fi
      fi
    fi

    # Access key 1 checks
    if [[ "${access_key1_active}" == "true" ]]; then
      echo "  Access Key 1: active" >> "${OUTPUT_FILE}"
      
      if [[ -n "${access_key1_last_rotated}" && "${access_key1_last_rotated}" != "N/A" ]]; then
        local key_age
        local rotated_epoch now_epoch
        rotated_epoch=$(date -d "${access_key1_last_rotated}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        key_age=$(( (now_epoch - rotated_epoch) / 86400 ))
        
        echo "  Access Key 1 Age: ${key_age} days" >> "${OUTPUT_FILE}"
        
        if (( key_age >= ACCESS_KEY_AGE_WARN_DAYS )); then
          ((old_access_keys++))
          echo "  WARNING: Access Key 1 older than ${ACCESS_KEY_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
        fi
      fi

      # Check for unused key
      if [[ -n "${access_key1_last_used}" && "${access_key1_last_used}" != "N/A" ]]; then
        local last_used_epoch now_epoch unused_days
        last_used_epoch=$(date -d "${access_key1_last_used}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        unused_days=$(( (now_epoch - last_used_epoch) / 86400 ))
        
        if (( unused_days >= UNUSED_CREDENTIAL_DAYS )); then
          ((unused_credentials++))
          echo "  WARNING: Access Key 1 not used in ${unused_days} days" >> "${OUTPUT_FILE}"
        fi
      fi
    fi

    # Access key 2 checks
    if [[ "${access_key2_active}" == "true" ]]; then
      echo "  Access Key 2: active" >> "${OUTPUT_FILE}"
      
      if [[ -n "${access_key2_last_rotated}" && "${access_key2_last_rotated}" != "N/A" ]]; then
        local key_age
        local rotated_epoch now_epoch
        rotated_epoch=$(date -d "${access_key2_last_rotated}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        key_age=$(( (now_epoch - rotated_epoch) / 86400 ))
        
        echo "  Access Key 2 Age: ${key_age} days" >> "${OUTPUT_FILE}"
        
        if (( key_age >= ACCESS_KEY_AGE_WARN_DAYS )); then
          ((old_access_keys++))
          echo "  WARNING: Access Key 2 older than ${ACCESS_KEY_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
        fi
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Credential Audit Summary:"
    echo "  Old Passwords: ${old_passwords}"
    echo "  Old Access Keys: ${old_access_keys}"
    echo "  Unused Credentials: ${unused_credentials}"
    echo "  Users Without MFA: ${no_mfa}"
    echo "  Root Access Keys: ${root_access_keys}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_roles() {
  log_message INFO "Auditing IAM roles"
  {
    echo "=== IAM ROLES AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local total_roles=0 service_roles=0 cross_account_roles=0

  local roles_json
  roles_json=$(list_roles)
  echo "${roles_json}" | jq -c '.Roles[]?' 2>/dev/null | while read -r role; do
    ((total_roles++))
    local role_name created trust_policy max_session
    role_name=$(echo "${role}" | jq_safe '.RoleName')
    created=$(echo "${role}" | jq_safe '.CreateDate')
    trust_policy=$(echo "${role}" | jq_safe '.AssumeRolePolicyDocument')
    max_session=$(echo "${role}" | jq_safe '.MaxSessionDuration')

    # Check for service roles
    local has_service_principal
    has_service_principal=$(echo "${trust_policy}" | jq '.Statement[]? | select(.Principal.Service)' 2>/dev/null | wc -l)
    
    if (( has_service_principal > 0 )); then
      ((service_roles++))
    fi

    # Check for cross-account trust
    local has_cross_account
    has_cross_account=$(echo "${trust_policy}" | jq '.Statement[]? | select(.Principal.AWS)' 2>/dev/null | wc -l)
    
    if (( has_cross_account > 0 )); then
      ((cross_account_roles++))
      {
        echo "Role: ${role_name}"
        echo "  Created: ${created}"
        echo "  Max Session Duration: ${max_session}s"
        echo "  INFO: Cross-account trust detected"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Role Summary:"
    echo "  Total Roles: ${total_roles}"
    echo "  Service Roles: ${service_roles}"
    echo "  Cross-Account Roles: ${cross_account_roles}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_policies() {
  log_message INFO "Auditing customer managed policies"
  {
    echo "=== CUSTOMER MANAGED POLICIES ==="
  } >> "${OUTPUT_FILE}"

  local overly_permissive=0 attached=0 unattached=0

  local policies_json
  policies_json=$(list_policies)
  echo "${policies_json}" | jq -c '.Policies[]?' 2>/dev/null | while read -r policy; do
    local policy_name policy_arn attachment_count default_version
    policy_name=$(echo "${policy}" | jq_safe '.PolicyName')
    policy_arn=$(echo "${policy}" | jq_safe '.Arn')
    attachment_count=$(echo "${policy}" | jq_safe '.AttachmentCount')
    default_version=$(echo "${policy}" | jq_safe '.DefaultVersionId')

    if (( attachment_count > 0 )); then
      ((attached++))
    else
      ((unattached++))
      {
        echo "Policy: ${policy_name}"
        echo "  ARN: ${policy_arn}"
        echo "  WARNING: Policy not attached to any entity"
        echo ""
      } >> "${OUTPUT_FILE}"
      continue
    fi

    # Get policy document
    local policy_doc
    policy_doc=$(get_policy_version "${policy_arn}" "${default_version}")
    local policy_text
    policy_text=$(echo "${policy_doc}" | jq_safe '.PolicyVersion.Document')

    # Check for wildcard actions and resources
    local has_wildcards
    has_wildcards=$(echo "${policy_text}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Action == "*" or (.Action | type == "array" and . | contains(["*"]))) and (.Resource == "*" or (.Resource | type == "array" and . | contains(["*"]))))' 2>/dev/null | wc -l)

    if (( has_wildcards > 0 )); then
      ((overly_permissive++))
      {
        echo "Policy: ${policy_name}"
        echo "  ARN: ${policy_arn}"
        echo "  Attachments: ${attachment_count}"
        echo "  WARNING: Policy has wildcard (*) for both Action and Resource"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Policy Summary:"
    echo "  Attached: ${attached}"
    echo "  Unattached: ${unattached}"
    echo "  Overly Permissive: ${overly_permissive}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local old_passwords="$1"; local old_keys="$2"; local no_mfa="$3"; local unused="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS IAM Security Audit Report",
  "attachments": [
    {
      "color": "danger",
      "fields": [
        {"title": "Old Passwords", "value": "${old_passwords}", "short": true},
        {"title": "Old Access Keys", "value": "${old_keys}", "short": true},
        {"title": "No MFA", "value": "${no_mfa}", "short": true},
        {"title": "Unused Credentials", "value": "${unused}", "short": true},
        {"title": "Password Age Warn", "value": "${PASSWORD_AGE_WARN_DAYS}d", "short": true},
        {"title": "Key Age Warn", "value": "${ACCESS_KEY_AGE_WARN_DAYS}d", "short": true},
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
  log_message INFO "Starting AWS IAM security audit"
  write_header
  report_account_summary
  audit_credential_report
  audit_roles
  audit_policies
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local old_passwords old_keys no_mfa unused
  old_passwords=$(grep "Old Passwords:" "${OUTPUT_FILE}" | awk '{print $NF}')
  old_keys=$(grep "Old Access Keys:" "${OUTPUT_FILE}" | awk '{print $NF}')
  no_mfa=$(grep "Users Without MFA:" "${OUTPUT_FILE}" | awk '{print $NF}')
  unused=$(grep "Unused Credentials:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${old_passwords}" "${old_keys}" "${no_mfa}" "${unused}"
  cat "${OUTPUT_FILE}"
}

main "$@"

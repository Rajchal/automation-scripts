#!/bin/bash

################################################################################
# AWS Secrets Manager Rotation Auditor
# Audits Secrets Manager secrets for rotation status, expiration, and access
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/secrets-manager-audit-$(date +%s).txt"
LOG_FILE="/var/log/secrets-manager-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ROTATION_AGE_WARN_DAYS="${ROTATION_AGE_WARN_DAYS:-90}"  # days since last rotation
SECRET_AGE_WARN_DAYS="${SECRET_AGE_WARN_DAYS:-365}"     # days since creation without rotation

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
list_secrets() {
  aws secretsmanager list-secrets \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_secret() {
  local secret_id="$1"
  aws secretsmanager describe-secret \
    --secret-id "${secret_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_resource_policy() {
  local secret_id="$1"
  aws secretsmanager get-resource-policy \
    --secret-id "${secret_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Secrets Manager Rotation Audit Report"
    echo "=========================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Rotation Age Warn: ${ROTATION_AGE_WARN_DAYS} days"
    echo "Secret Age Warn: ${SECRET_AGE_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_secrets() {
  log_message INFO "Auditing Secrets Manager secrets"
  {
    echo "=== SECRETS AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local total=0 rotation_enabled=0 rotation_disabled=0 old_no_rotation=0 stale_rotation=0 deleted=0

  local secrets_json
  secrets_json=$(list_secrets)
  echo "${secrets_json}" | jq -c '.SecretList[]?' 2>/dev/null | while read -r secret; do
    ((total++))
    local name arn created last_changed last_accessed last_rotated rotation_enabled_flag rotation_rules kms_key description deleted_date tags
    name=$(echo "${secret}" | jq_safe '.Name')
    arn=$(echo "${secret}" | jq_safe '.ARN')
    created=$(echo "${secret}" | jq_safe '.CreatedDate')
    last_changed=$(echo "${secret}" | jq_safe '.LastChangedDate')
    last_accessed=$(echo "${secret}" | jq_safe '.LastAccessedDate')
    last_rotated=$(echo "${secret}" | jq_safe '.LastRotatedDate')
    rotation_enabled_flag=$(echo "${secret}" | jq_safe '.RotationEnabled')
    rotation_rules=$(echo "${secret}" | jq_safe '.RotationRules')
    kms_key=$(echo "${secret}" | jq_safe '.KmsKeyId')
    description=$(echo "${secret}" | jq_safe '.Description')
    deleted_date=$(echo "${secret}" | jq_safe '.DeletedDate')
    tags=$(echo "${secret}" | jq -c '.Tags' 2>/dev/null || echo '[]')

    {
      echo "Secret: ${name}"
      echo "  ARN: ${arn}"
      echo "  Description: ${description}"
      echo "  Created: ${created}"
      echo "  Last Changed: ${last_changed}"
      echo "  Last Accessed: ${last_accessed}"
    } >> "${OUTPUT_FILE}"

    # Check if deleted
    if [[ -n "${deleted_date}" && "${deleted_date}" != "null" ]]; then
      ((deleted++))
      echo "  Status: SCHEDULED FOR DELETION (${deleted_date})" >> "${OUTPUT_FILE}"
      echo "  WARNING: Secret is scheduled for deletion" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    # KMS encryption
    if [[ -n "${kms_key}" && "${kms_key}" != "null" ]]; then
      echo "  KMS Key: ${kms_key}" >> "${OUTPUT_FILE}"
    else
      echo "  KMS Key: aws/secretsmanager (default)" >> "${OUTPUT_FILE}"
    fi

    # Rotation status
    if [[ "${rotation_enabled_flag}" == "true" ]]; then
      ((rotation_enabled++))
      echo "  Rotation: ENABLED" >> "${OUTPUT_FILE}"
      
      # Parse rotation rules
      local rotation_days
      rotation_days=$(echo "${rotation_rules}" | jq_safe '.AutomaticallyAfterDays')
      if [[ -n "${rotation_days}" && "${rotation_days}" != "null" ]]; then
        echo "  Rotation Interval: ${rotation_days} days" >> "${OUTPUT_FILE}"
      fi

      # Check last rotation date
      if [[ -n "${last_rotated}" && "${last_rotated}" != "null" ]]; then
        echo "  Last Rotated: ${last_rotated}" >> "${OUTPUT_FILE}"
        
        local last_rotation_epoch now_epoch days_since_rotation
        last_rotation_epoch=$(date -d "${last_rotated}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_since_rotation=$(( (now_epoch - last_rotation_epoch) / 86400 ))
        
        echo "  Days Since Rotation: ${days_since_rotation}" >> "${OUTPUT_FILE}"
        
        if (( days_since_rotation >= ROTATION_AGE_WARN_DAYS )); then
          ((stale_rotation++))
          echo "  WARNING: Last rotation was ${days_since_rotation} days ago (>= ${ROTATION_AGE_WARN_DAYS}d)" >> "${OUTPUT_FILE}"
        fi
      else
        echo "  Last Rotated: never" >> "${OUTPUT_FILE}"
        echo "  WARNING: Rotation enabled but secret has never been rotated" >> "${OUTPUT_FILE}"
      fi
    else
      ((rotation_disabled++))
      echo "  Rotation: DISABLED" >> "${OUTPUT_FILE}"
      
      # Check secret age without rotation
      if [[ -n "${created}" && "${created}" != "null" ]]; then
        local creation_epoch now_epoch secret_age_days
        creation_epoch=$(date -d "${created}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        secret_age_days=$(( (now_epoch - creation_epoch) / 86400 ))
        
        echo "  Age: ${secret_age_days} days" >> "${OUTPUT_FILE}"
        
        if (( secret_age_days >= SECRET_AGE_WARN_DAYS )); then
          ((old_no_rotation++))
          echo "  WARNING: Secret is ${secret_age_days} days old without rotation (>= ${SECRET_AGE_WARN_DAYS}d)" >> "${OUTPUT_FILE}"
        fi
      fi
    fi

    # Check last access
    if [[ -n "${last_accessed}" && "${last_accessed}" != "null" ]]; then
      local last_access_epoch now_epoch days_since_access
      last_access_epoch=$(date -d "${last_accessed}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      days_since_access=$(( (now_epoch - last_access_epoch) / 86400 ))
      
      echo "  Days Since Last Access: ${days_since_access}" >> "${OUTPUT_FILE}"
      
      if (( days_since_access >= 90 )); then
        echo "  INFO: Secret not accessed in ${days_since_access} days (potentially unused)" >> "${OUTPUT_FILE}"
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Secrets Summary:"
    echo "  Total: ${total}"
    echo "  Rotation Enabled: ${rotation_enabled}"
    echo "  Rotation Disabled: ${rotation_disabled}"
    echo "  Old Without Rotation: ${old_no_rotation}"
    echo "  Stale Rotation: ${stale_rotation}"
    echo "  Scheduled for Deletion: ${deleted}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_resource_policies() {
  log_message INFO "Auditing resource policies for cross-account access"
  {
    echo "=== RESOURCE POLICY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local secrets_with_policy=0 cross_account=0

  local secrets_json
  secrets_json=$(list_secrets)
  echo "${secrets_json}" | jq -c '.SecretList[]?' 2>/dev/null | while read -r secret; do
    local name
    name=$(echo "${secret}" | jq_safe '.Name')

    local policy_json
    policy_json=$(get_resource_policy "${name}")
    local policy
    policy=$(echo "${policy_json}" | jq_safe '.ResourcePolicy')

    if [[ -z "${policy}" || "${policy}" == "null" ]]; then
      continue
    fi

    ((secrets_with_policy++))

    # Check for cross-account access
    local has_cross_account
    has_cross_account=$(echo "${policy}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal.AWS | tostring | contains(":root")))' 2>/dev/null | wc -l)

    {
      echo "Secret: ${name}"
      echo "  Resource Policy: present"
    } >> "${OUTPUT_FILE}"

    if (( has_cross_account > 0 )); then
      ((cross_account++))
      echo "  WARNING: Policy allows cross-account access" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Resource Policy Summary:"
    echo "  Secrets with Policies: ${secrets_with_policy}"
    echo "  Cross-Account Access: ${cross_account}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_rotation_lambdas() {
  log_message INFO "Checking rotation Lambda functions"
  {
    echo "=== ROTATION LAMBDA FUNCTIONS ==="
  } >> "${OUTPUT_FILE}"

  local rotation_lambdas=0

  local secrets_json
  secrets_json=$(list_secrets)
  echo "${secrets_json}" | jq -c '.SecretList[]?' 2>/dev/null | while read -r secret; do
    local name rotation_enabled rotation_lambda
    name=$(echo "${secret}" | jq_safe '.Name')
    rotation_enabled=$(echo "${secret}" | jq_safe '.RotationEnabled')
    rotation_lambda=$(echo "${secret}" | jq_safe '.RotationLambdaARN')

    if [[ "${rotation_enabled}" == "true" && -n "${rotation_lambda}" && "${rotation_lambda}" != "null" ]]; then
      ((rotation_lambdas++))
      {
        echo "Secret: ${name}"
        echo "  Rotation Lambda: ${rotation_lambda}"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Rotation Lambda Summary:"
    echo "  Secrets with Lambda Rotation: ${rotation_lambdas}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_replicated_secrets() {
  log_message INFO "Checking for replicated secrets"
  {
    echo "=== REPLICATED SECRETS ==="
  } >> "${OUTPUT_FILE}"

  local replicated_count=0

  local secrets_json
  secrets_json=$(list_secrets)
  echo "${secrets_json}" | jq -c '.SecretList[]?' 2>/dev/null | while read -r secret; do
    local name
    name=$(echo "${secret}" | jq_safe '.Name')

    local details
    details=$(describe_secret "${name}")
    local replication_status
    replication_status=$(echo "${details}" | jq -c '.ReplicationStatus' 2>/dev/null || echo '[]')

    local replica_count
    replica_count=$(echo "${replication_status}" | jq 'length' 2>/dev/null || echo 0)

    if (( replica_count > 0 )); then
      ((replicated_count++))
      {
        echo "Secret: ${name}"
        echo "  Replicas: ${replica_count}"
      } >> "${OUTPUT_FILE}"

      echo "${replication_status}" | jq -c '.[]?' 2>/dev/null | while read -r replica; do
        local region status
        region=$(echo "${replica}" | jq_safe '.Region')
        status=$(echo "${replica}" | jq_safe '.Status')
        echo "    Region: ${region} (Status: ${status})" >> "${OUTPUT_FILE}"
      done

      echo "" >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Replication Summary:"
    echo "  Replicated Secrets: ${replicated_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local no_rotation="$2"; local old_no_rotation="$3"; local stale="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Secrets Manager Rotation Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Total Secrets", "value": "${total}", "short": true},
        {"title": "Rotation Disabled", "value": "${no_rotation}", "short": true},
        {"title": "Old Without Rotation", "value": "${old_no_rotation}", "short": true},
        {"title": "Stale Rotation", "value": "${stale}", "short": true},
        {"title": "Rotation Age Warn", "value": "${ROTATION_AGE_WARN_DAYS}d", "short": true},
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
  log_message INFO "Starting AWS Secrets Manager rotation audit"
  write_header
  report_secrets
  audit_resource_policies
  report_rotation_lambdas
  report_replicated_secrets
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total no_rotation old_no_rotation stale
  total=$(grep "Total:" "${OUTPUT_FILE}" | grep "Secrets Summary" -A1 | tail -1 | awk '{print $NF}')
  no_rotation=$(grep "Rotation Disabled:" "${OUTPUT_FILE}" | awk '{print $NF}')
  old_no_rotation=$(grep "Old Without Rotation:" "${OUTPUT_FILE}" | awk '{print $NF}')
  stale=$(grep "Stale Rotation:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total}" "${no_rotation}" "${old_no_rotation}" "${stale}"
  cat "${OUTPUT_FILE}"
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-kms-key-rotation-auditor.log"
REPORT_FILE="/tmp/kms-key-rotation-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS KMS Key Rotation & Policy Auditor - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_key() {
  local key_id="$1"
  local key_meta
  key_meta=$(aws kms describe-key --key-id "$key_id" --output json 2>/dev/null || echo '{}')
  key_arn=$(echo "$key_meta" | jq -r '.KeyMetadata.Arn // ""')
  key_state=$(echo "$key_meta" | jq -r '.KeyMetadata.KeyState // ""')
  key_manager=$(echo "$key_meta" | jq -r '.KeyMetadata.KeyManager // ""')
  key_desc=$(echo "$key_meta" | jq -r '.KeyMetadata.Description // ""')

  echo "Key: $key_id ($key_arn)" >> "$REPORT_FILE"
  echo "  State: $key_state Manager: $key_manager" >> "$REPORT_FILE"

  if [ "$key_manager" = "AWS" ]; then
    echo "  AWS-managed key (skipping rotation checks)" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    return
  fi

  # rotation status
  rotation_enabled=$(aws kms get-key-rotation-status --key-id "$key_id" --output json 2>/dev/null | jq -r '.KeyRotationEnabled // false' || echo "false")
  if [ "$rotation_enabled" != "true" ]; then
    echo "  ROTATION_DISABLED" >> "$REPORT_FILE"
    send_slack_alert "KMS Alert: Rotation disabled for key $key_id ($key_arn)"
  else
    echo "  Rotation enabled" >> "$REPORT_FILE"
  fi

  # list aliases
  aws kms list-aliases --key-id "$key_id" --output json 2>/dev/null | jq -c '.Aliases[]? // empty' | while read -r a; do
    alias_name=$(echo "$a" | jq -r '.AliasName // ""')
    echo "  Alias: $alias_name" >> "$REPORT_FILE"
  done

  # check key policy for overly permissive principals
  policy=$(aws kms get-key-policy --key-id "$key_id" --policy-name default --output text 2>/dev/null || echo "")
  if [ -z "$policy" ]; then
    echo "  POLICY_MISSING" >> "$REPORT_FILE"
    send_slack_alert "KMS Alert: No key policy found for $key_id"
  else
    # heuristic checks
    if echo "$policy" | grep -q '"Principal"[[:space:]]*:[[:space:]]*"\*"' || echo "$policy" | grep -q '"AWS"[[:space:]]*:[[:space:]]*"\*"'; then
      echo "  POLICY_PERMISSIVE: principal='*' or AWS='*'" >> "$REPORT_FILE"
      send_slack_alert "KMS Alert: Key policy for $key_id appears permissive (wildcard principal)"
    else
      echo "  Policy appears restricted (no wildcard principal detected)" >> "$REPORT_FILE"
    fi
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  keys_json=$(aws kms list-keys --output json 2>/dev/null || echo '{"Keys":[]}')
  echo "$keys_json" | jq -c '.Keys[]? // empty' | while read -r k; do
    kid=$(echo "$k" | jq -r '.KeyId')
    check_key "$kid"
  done

  log_message "KMS audit written to $REPORT_FILE"
}

main "$@"
#!/bin/bash

################################################################################
# AWS KMS Key Rotation Auditor
# Audits KMS keys for rotation status, disabled keys, and potential security issues
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/kms-audit-$(date +%s).txt"
LOG_FILE="/var/log/kms-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
ROTATION_AGE_WARN_DAYS="${ROTATION_AGE_WARN_DAYS:-365}"  # days since last rotation
KEY_AGE_WARN_DAYS="${KEY_AGE_WARN_DAYS:-730}"            # 2 years

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
list_keys() {
  aws kms list-keys \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
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
    --output json 2>/dev/null || echo '{}'
}

list_aliases() {
  aws kms list-aliases \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_grants() {
  local key_id="$1"
  aws kms list-grants \
    --key-id "${key_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_key_policy() {
  local key_id="$1"
  aws kms get-key-policy \
    --key-id "${key_id}" \
    --policy-name default \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS KMS Key Rotation Audit Report"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Rotation Age Warn: ${ROTATION_AGE_WARN_DAYS} days"
    echo "Key Age Warn: ${KEY_AGE_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_customer_managed_keys() {
  log_message INFO "Auditing customer-managed KMS keys"
  {
    echo "=== CUSTOMER MANAGED KEYS ==="
  } >> "${OUTPUT_FILE}"

  local total=0 enabled=0 disabled=0 pending_deletion=0 rotation_enabled=0 rotation_disabled=0 old_keys=0 no_rotation_old=0

  local keys_json
  keys_json=$(list_keys)
  echo "${keys_json}" | jq -c '.Keys[]?' 2>/dev/null | while read -r key; do
    local key_id
    key_id=$(echo "${key}" | jq_safe '.KeyId')

    local key_details
    key_details=$(describe_key "${key_id}")

    local key_state manager origin creation_date arn description
    key_state=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyState')
    manager=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyManager')
    origin=$(echo "${key_details}" | jq_safe '.KeyMetadata.Origin')
    creation_date=$(echo "${key_details}" | jq_safe '.KeyMetadata.CreationDate')
    arn=$(echo "${key_details}" | jq_safe '.KeyMetadata.Arn')
    description=$(echo "${key_details}" | jq_safe '.KeyMetadata.Description')

    # Skip AWS-managed keys
    [[ "${manager}" == "AWS" ]] && continue

    ((total++))

    # Get aliases
    local aliases_json alias_names
    aliases_json=$(list_aliases)
    alias_names=$(echo "${aliases_json}" | jq -r ".Aliases[] | select(.TargetKeyId==\"${key_id}\") | .AliasName" 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    {
      echo "Key ID: ${key_id}"
      echo "  State: ${key_state}"
      echo "  Origin: ${origin}"
      echo "  Manager: ${manager}"
      echo "  Aliases: ${alias_names:-none}"
      echo "  Description: ${description}"
      echo "  Created: ${creation_date}"
    } >> "${OUTPUT_FILE}"

    # Count by state
    case "${key_state}" in
      "Enabled") ((enabled++)) ;;
      "Disabled") ((disabled++)) ;;
      "PendingDeletion") ((pending_deletion++)) ;;
    esac

    # Check key age
    if [[ -n "${creation_date}" && "${creation_date}" != "null" ]]; then
      local creation_epoch now_epoch age_days
      creation_epoch=$(date -d "${creation_date}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      age_days=$(( (now_epoch - creation_epoch) / 86400 ))
      
      echo "  Age: ${age_days} days" >> "${OUTPUT_FILE}"

      if (( age_days >= KEY_AGE_WARN_DAYS )); then
        ((old_keys++))
        echo "  INFO: Key is older than ${KEY_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
      fi
    fi

    # Check rotation (only for symmetric keys with AWS_KMS origin)
    if [[ "${origin}" == "AWS_KMS" && "${key_state}" == "Enabled" ]]; then
      local rotation_status rotation_enabled_flag
      rotation_status=$(get_key_rotation_status "${key_id}")
      rotation_enabled_flag=$(echo "${rotation_status}" | jq_safe '.KeyRotationEnabled')

      if [[ "${rotation_enabled_flag}" == "true" ]]; then
        ((rotation_enabled++))
        echo "  Rotation: ENABLED" >> "${OUTPUT_FILE}"
      else
        ((rotation_disabled++))
        echo "  Rotation: DISABLED" >> "${OUTPUT_FILE}"
        
        # Check if old key without rotation
        if [[ -n "${creation_date}" && "${creation_date}" != "null" ]]; then
          local creation_epoch now_epoch age_days
          creation_epoch=$(date -d "${creation_date}" +%s 2>/dev/null || echo 0)
          now_epoch=$(date +%s)
          age_days=$(( (now_epoch - creation_epoch) / 86400 ))
          
          if (( age_days >= ROTATION_AGE_WARN_DAYS )); then
            ((no_rotation_old++))
            echo "  WARNING: Rotation disabled on key older than ${ROTATION_AGE_WARN_DAYS} days" >> "${OUTPUT_FILE}"
          fi
        fi
      fi
    elif [[ "${origin}" != "AWS_KMS" ]]; then
      echo "  Rotation: N/A (${origin} origin)" >> "${OUTPUT_FILE}"
    fi

    # Check grants
    local grants_json grant_count
    grants_json=$(list_grants "${key_id}")
    grant_count=$(echo "${grants_json}" | jq '.Grants | length' 2>/dev/null || echo 0)
    echo "  Grants: ${grant_count}" >> "${OUTPUT_FILE}"

    # State warnings
    if [[ "${key_state}" == "Disabled" ]]; then
      echo "  WARNING: Key is disabled" >> "${OUTPUT_FILE}"
    elif [[ "${key_state}" == "PendingDeletion" ]]; then
      local deletion_date
      deletion_date=$(echo "${key_details}" | jq_safe '.KeyMetadata.DeletionDate')
      echo "  WARNING: Key pending deletion on ${deletion_date}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Customer Managed Keys Summary:"
    echo "  Total: ${total}"
    echo "  Enabled: ${enabled}"
    echo "  Disabled: ${disabled}"
    echo "  Pending Deletion: ${pending_deletion}"
    echo "  Rotation Enabled: ${rotation_enabled}"
    echo "  Rotation Disabled: ${rotation_disabled}"
    echo "  Old Keys (>${KEY_AGE_WARN_DAYS}d): ${old_keys}"
    echo "  Old Keys Without Rotation: ${no_rotation_old}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_aws_managed_keys() {
  log_message INFO "Listing AWS-managed KMS keys"
  {
    echo "=== AWS MANAGED KEYS ==="
  } >> "${OUTPUT_FILE}"

  local aws_managed_count=0

  local keys_json
  keys_json=$(list_keys)
  echo "${keys_json}" | jq -c '.Keys[]?' 2>/dev/null | while read -r key; do
    local key_id
    key_id=$(echo "${key}" | jq_safe '.KeyId')

    local key_details manager
    key_details=$(describe_key "${key_id}")
    manager=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyManager')

    [[ "${manager}" != "AWS" ]] && continue
    ((aws_managed_count++))

    local key_state description
    key_state=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyState')
    description=$(echo "${key_details}" | jq_safe '.KeyMetadata.Description')

    {
      echo "Key ID: ${key_id}"
      echo "  Description: ${description}"
      echo "  State: ${key_state}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done

  {
    echo "AWS Managed Keys Summary:"
    echo "  Total: ${aws_managed_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_key_policies() {
  log_message INFO "Auditing key policies for public access"
  {
    echo "=== KEY POLICY AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local public_access=0 wildcard_principal=0

  local keys_json
  keys_json=$(list_keys)
  echo "${keys_json}" | jq -c '.Keys[]?' 2>/dev/null | while read -r key; do
    local key_id
    key_id=$(echo "${key}" | jq_safe '.KeyId')

    local key_details manager
    key_details=$(describe_key "${key_id}")
    manager=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyManager')

    # Skip AWS-managed keys
    [[ "${manager}" == "AWS" ]] && continue

    local policy
    policy=$(get_key_policy "${key_id}")

    # Check for wildcard principals
    local has_wildcard
    has_wildcard=$(echo "${policy}" | jq '.Statement[]? | select(.Effect=="Allow" and (.Principal=="*" or .Principal.AWS=="*"))' 2>/dev/null | wc -l)

    if (( has_wildcard > 0 )); then
      ((wildcard_principal++))
      {
        echo "Key ID: ${key_id}"
        echo "  WARNING: Policy contains wildcard principal (*)"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Policy Audit Summary:"
    echo "  Keys with Wildcard Principal: ${wildcard_principal}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_orphaned_aliases() {
  log_message INFO "Checking for orphaned aliases"
  {
    echo "=== ORPHANED ALIASES ==="
  } >> "${OUTPUT_FILE}"

  local orphaned=0

  local aliases_json
  aliases_json=$(list_aliases)
  echo "${aliases_json}" | jq -c '.Aliases[]?' 2>/dev/null | while read -r alias; do
    local alias_name target_key
    alias_name=$(echo "${alias}" | jq_safe '.AliasName')
    target_key=$(echo "${alias}" | jq_safe '.TargetKeyId')

    if [[ -z "${target_key}" || "${target_key}" == "null" ]]; then
      ((orphaned++))
      {
        echo "Alias: ${alias_name}"
        echo "  WARNING: Alias has no target key (orphaned)"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Alias Summary:"
    echo "  Orphaned Aliases: ${orphaned}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local disabled="$2"; local no_rotation="$3"; local pending_del="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS KMS Key Rotation Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Customer Keys", "value": "${total}", "short": true},
        {"title": "Disabled", "value": "${disabled}", "short": true},
        {"title": "Pending Deletion", "value": "${pending_del}", "short": true},
        {"title": "Old Keys No Rotation", "value": "${no_rotation}", "short": true},
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
  log_message INFO "Starting AWS KMS key rotation audit"
  write_header
  report_customer_managed_keys
  report_aws_managed_keys
  audit_key_policies
  report_orphaned_aliases
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total disabled no_rotation pending_del
  total=$(grep -c "^Key ID:" "${OUTPUT_FILE}" | head -1 || echo 0)
  disabled=$(grep -c "WARNING: Key is disabled" "${OUTPUT_FILE}" || echo 0)
  no_rotation=$(grep -c "Old Keys Without Rotation:" "${OUTPUT_FILE}" | tail -1 | awk '{print $NF}' || echo 0)
  pending_del=$(grep -c "WARNING: Key pending deletion" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${total}" "${disabled}" "${no_rotation}" "${pending_del}"
  cat "${OUTPUT_FILE}"
}

main "$@"

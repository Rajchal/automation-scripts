#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-secretsmanager-rotation-auditor.log"
REPORT_FILE="/tmp/secretsmanager-rotation-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"
ROTATION_MAX_AGE_DAYS="${SECRETS_ROTATION_MAX_AGE_DAYS:-90}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS Secrets Manager Rotation Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Rotation max age (days): $ROTATION_MAX_AGE_DAYS" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_secret() {
  local arn="$1"
  local name="$2"

  echo "Secret: $name ($arn)" >> "$REPORT_FILE"

  desc=$(aws secretsmanager describe-secret --secret-id "$arn" --output json 2>/dev/null || echo '{}')
  rotation_enabled=$(echo "$desc" | jq -r '.RotationEnabled // false')
  last_changed=$(echo "$desc" | jq -r '.LastChangedDate // .CreatedDate // empty')

  if [ "$rotation_enabled" != "true" ]; then
    echo "  ROTATION_DISABLED" >> "$REPORT_FILE"
    send_slack_alert "SecretsManager Alert: Secret $name has rotation disabled"
  else
    echo "  Rotation enabled" >> "$REPORT_FILE"
  fi

  if [ -n "$last_changed" ] && [ "$last_changed" != "null" ]; then
    # convert to epoch
    last_epoch=$(date -d "$last_changed" +%s 2>/dev/null || true)
    if [ -n "$last_epoch" ]; then
      now=$(date +%s)
      age_days=$(( (now - last_epoch) / 86400 ))
      echo "  Last changed: $last_changed (age: ${age_days}d)" >> "$REPORT_FILE"
      if [ "$age_days" -ge "$ROTATION_MAX_AGE_DAYS" ]; then
        echo "  ROTATION_AGE_EXCEEDED: ${age_days}d >= ${ROTATION_MAX_AGE_DAYS}d" >> "$REPORT_FILE"
        send_slack_alert "SecretsManager Alert: Secret $name last changed ${age_days} days ago (>= ${ROTATION_MAX_AGE_DAYS})"
      fi
    fi
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  # paginate through secrets
  next_token=""
  while :; do
    if [ -z "$next_token" ]; then
      out=$(aws secretsmanager list-secrets --output json 2>/dev/null || echo '{"SecretList":[]}')
    else
      out=$(aws secretsmanager list-secrets --output json --starting-token "$next_token" 2>/dev/null || echo '{"SecretList":[]}')
    fi

    echo "$out" | jq -c '.SecretList[]? // empty' | while read -r s; do
      sarn=$(echo "$s" | jq -r '.ARN')
      sname=$(echo "$s" | jq -r '.Name')
      check_secret "$sarn" "$sname"
    done

    next_token=$(echo "$out" | jq -r '.NextToken // empty')
    if [ -z "$next_token" ]; then
      break
    fi
  done

  log_message "Secrets Manager rotation audit written to $REPORT_FILE"
}

main "$@"
#!/bin/bash

################################################################################
# AWS Secrets Manager Rotation Auditor
# Audits secrets for rotation status, age, pending versions, risky policies,
# and provides remediation recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/secrets-rotation-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/secrets-rotation-auditor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
ROTATION_AGE_WARN_DAYS="${ROTATION_AGE_WARN_DAYS:-90}"   # days since last rotation
STALE_SECRET_WARN_DAYS="${STALE_SECRET_WARN_DAYS:-180}"   # days since last change
PENDING_MAX_DAYS="${PENDING_MAX_DAYS:-7}"                 # pending version age

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_SECRETS=0
ROTATION_DISABLED=0
OVERDUE_ROTATIONS=0
STALE_SECRETS=0
RISKY_POLICIES=0
PENDING_STUCK=0

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

days_since() {
  local date_str="$1"
  [[ -z "${date_str}" || "${date_str}" == "null" ]] && { echo 0; return; }
  local t
  t=$(date -d "${date_str}" +%s 2>/dev/null || echo 0)
  local now
  now=$(date +%s)
  echo $(( (now - t) / 86400 ))
}

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
      "title": "Secrets Manager Alert",
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
    echo "AWS Secrets Manager Rotation Auditor"
    echo "====================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
    echo "Thresholds:"
    echo "  Rotation age warning: ${ROTATION_AGE_WARN_DAYS} days"
    echo "  Stale secret warning: ${STALE_SECRET_WARN_DAYS} days"
    echo "  Pending version max age: ${PENDING_MAX_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_secrets() {
  aws secretsmanager list-secrets \
    --region "${REGION}" \
    --max-items 100 \
    --output json 2>/dev/null || echo '{"SecretList":[]}'
}

describe_secret() {
  local arn="$1"
  aws secretsmanager describe-secret \
    --secret-id "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_secret_versions() {
  local arn="$1"
  aws secretsmanager list-secret-version-ids \
    --secret-id "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Versions":[]}'
}

get_resource_policy() {
  local arn="$1"
  aws secretsmanager get-resource-policy \
    --secret-id "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

analyze_secrets() {
  log_message INFO "Starting secrets audit"
  {
    echo "=== SECRETS INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"

  local secrets_json
  secrets_json=$(list_secrets)

  local count
  count=$(echo "${secrets_json}" | jq '.SecretList | length' 2>/dev/null || echo "0")
  TOTAL_SECRETS=${count}

  if [[ ${count} -eq 0 ]]; then
    {
      echo "No secrets found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi

  {
    echo "Total Secrets: ${count}"
    echo ""
  } >> "${OUTPUT_FILE}"

  local secrets
  secrets=$(echo "${secrets_json}" | jq -c '.SecretList[]' 2>/dev/null)

  while IFS= read -r secret; do
    [[ -z "${secret}" ]] && continue

    local name arn rotation_enabled last_rotated last_changed kms_key created_date
    name=$(echo "${secret}" | jq_safe '.Name')
    arn=$(echo "${secret}" | jq_safe '.ARN')
    rotation_enabled=$(echo "${secret}" | jq_safe '.RotationEnabled')
    last_rotated=$(echo "${secret}" | jq_safe '.LastRotatedDate')
    last_changed=$(echo "${secret}" | jq_safe '.LastChangedDate')
    created_date=$(echo "${secret}" | jq_safe '.CreatedDate')
    kms_key=$(echo "${secret}" | jq_safe '.KmsKeyId // "aws/secretsmanager"')

    local days_since_rotation days_since_change
    days_since_rotation=$(days_since "${last_rotated}")
    days_since_change=$(days_since "${last_changed}")

    {
      echo "Secret: ${name}"
      echo "ARN: ${arn}"
      echo "KMS Key: ${kms_key}"
      echo "Rotation Enabled: ${rotation_enabled}"
      echo "Last Rotated: ${last_rotated:-N/A} (${days_since_rotation}d)"
      echo "Last Changed: ${last_changed:-N/A} (${days_since_change}d)"
    } >> "${OUTPUT_FILE}"

    # Rotation status
    if [[ "${rotation_enabled}" != "true" ]]; then
      ((ROTATION_DISABLED++))
      {
        printf "  %b⚠️  Rotation disabled%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Rotation disabled for secret ${name}"
    elif [[ ${days_since_rotation} -gt ${ROTATION_AGE_WARN_DAYS} ]]; then
      ((OVERDUE_ROTATIONS++))
      {
        printf "  %b⚠️  Rotation overdue (%dd > %dd)%b\n" "${YELLOW}" "${days_since_rotation}" "${ROTATION_AGE_WARN_DAYS}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Secret ${name} rotation overdue (${days_since_rotation}d)"
    else
      {
        printf "  %b✓ Rotation healthy%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi

    # Stale secret
    if [[ ${days_since_change} -gt ${STALE_SECRET_WARN_DAYS} ]]; then
      ((STALE_SECRETS++))
      {
        printf "  %b⚠️  Secret stale (%dd > %dd)%b\n" "${YELLOW}" "${days_since_change}" "${STALE_SECRET_WARN_DAYS}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi

    # Pending versions stuck
    analyze_versions "${arn}" "${name}"

    # Policy analysis
    analyze_policy "${arn}" "${name}"

    {
      echo ""
    } >> "${OUTPUT_FILE}"
  done <<< "${secrets}"
}

analyze_versions() {
  local arn="$1"
  local name="$2"

  local versions_json
  versions_json=$(list_secret_versions "${arn}")

  local pending_versions
  pending_versions=$(echo "${versions_json}" | jq -c '.Versions[] | select(.VersionStages[]? == "AWSPENDING")' 2>/dev/null)

  if [[ -z "${pending_versions}" ]]; then
    return
  fi

  while IFS= read -r version; do
    [[ -z "${version}" ]] && continue
    local created_date
    created_date=$(echo "${version}" | jq_safe '.CreatedDate')
    local age_days
    age_days=$(days_since "${created_date}")
    if [[ ${age_days} -gt ${PENDING_MAX_DAYS} ]]; then
      ((PENDING_STUCK++))
      {
        printf "  %b⚠️  Pending version stuck (%dd > %dd)%b\n" "${YELLOW}" "${age_days}" "${PENDING_MAX_DAYS}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Secret ${name} has pending version ${age_days}d old"
    fi
  done <<< "${pending_versions}"
}

analyze_policy() {
  local arn="$1"
  local name="$2"

  local policy_json
  policy_json=$(get_resource_policy "${arn}")

  local policy_str
  policy_str=$(echo "${policy_json}" | jq_safe '.ResourcePolicy')

  if [[ -z "${policy_str}" || "${policy_str}" == "null" ]]; then
    return
  fi

  # Detect wildcards in Principal
  if echo "${policy_str}" | grep -q '"Principal"\s*:\s*"\*"'; then
    ((RISKY_POLICIES++))
    {
      printf "  %b⚠️  Risky policy detected (Principal: *)%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Secret ${name} has wildcard principal in policy"
  fi

  # Detect broad actions
  if echo "${policy_str}" | grep -q '"Action"\s*:\s*"secretsmanager:\*"'; then
    ((RISKY_POLICIES++))
    {
      printf "  %b⚠️  Broad action (secretsmanager:*) in policy%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Secret ${name} policy grants secretsmanager:*"
  fi
}

generate_summary() {
  {
    echo ""
    echo "=== SECRETS AUDIT SUMMARY ==="
    echo ""
    printf "Total Secrets: %d\n" "${TOTAL_SECRETS}"
    printf "Rotation Disabled: %d\n" "${ROTATION_DISABLED}"
    printf "Overdue Rotations: %d\n" "${OVERDUE_ROTATIONS}"
    printf "Stale Secrets: %d\n" "${STALE_SECRETS}"
    printf "Stuck Pending Versions: %d\n" "${PENDING_STUCK}"
    printf "Risky Policies: %d\n" "${RISKY_POLICIES}"
    echo ""

    if [[ ${ROTATION_DISABLED} -gt 0 || ${OVERDUE_ROTATIONS} -gt 0 || ${RISKY_POLICIES} -gt 0 ]]; then
      printf "%b[WARNING] Secrets require attention%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Secrets rotation posture is healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${ROTATION_DISABLED} -gt 0 ]]; then
      echo "Rotation Setup:"
      echo "  • Enable rotation with AWS-provided Lambda templates"
      echo "  • Use rotation interval of 30-90 days based on sensitivity"
      echo "  • Ensure rotation Lambda has least-privilege IAM role"
      echo ""
    fi
    if [[ ${OVERDUE_ROTATIONS} -gt 0 ]]; then
      echo "Overdue Rotation Remediation:"
      echo "  • Trigger manual rotation via CLI or console"
      echo "  • Validate rotation Lambda success metrics"
      echo "  • Add CloudWatch alarms on RotationFailed events"
      echo ""
    fi
    if [[ ${PENDING_STUCK} -gt 0 ]]; then
      echo "Pending Version Cleanup:"
      echo "  • Investigate rotation Lambda errors"
      echo "  • Clear stale AWSPENDING versions if rotation failed"
      echo "  • Re-run rotation after fixing issues"
      echo ""
    fi
    if [[ ${RISKY_POLICIES} -gt 0 ]]; then
      echo "Policy Hardening:"
      echo "  • Remove wildcard principals; scope to roles/accounts"
      echo "  • Limit actions to needed operations (GetSecretValue)"
      echo "  • Deny cross-account access unless required"
      echo "  • Use resource policies only when necessary"
      echo ""
    fi
    echo "Operational Best Practices:"
    echo "  • Tag secrets with owner, environment, rotation interval"
    echo "  • Use customer-managed KMS keys for sensitive secrets"
    echo "  • Enable CloudTrail data events for Secrets Manager"
    echo "  • Monitor RotationFailed and SecretRotation events"
    echo "  • Set CloudWatch alarms on pending version age and rotation age"
    echo "  • Regularly prune unused or test secrets"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Secrets Manager Rotation Auditor Started ==="

  write_header
  analyze_secrets
  generate_summary
  recommendations

  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "Enable rotation example:" 
    echo "  aws secretsmanager rotate-secret --secret-id <arn>"
  } >> "${OUTPUT_FILE}"

  cat "${OUTPUT_FILE}"

  log_message INFO "=== Secrets Manager Rotation Auditor Completed ==="

  if [[ ${OVERDUE_ROTATIONS} -gt 0 || ${ROTATION_DISABLED} -gt 0 || ${RISKY_POLICIES} -gt 0 ]]; then
    send_slack_alert "⚠️ Secrets audit: rotation issues detected (disabled=${ROTATION_DISABLED}, overdue=${OVERDUE_ROTATIONS}, risky_policies=${RISKY_POLICIES})" "WARNING"
    send_email_alert "Secrets Manager Audit Alert" "$(cat "${OUTPUT_FILE}")"
  fi
}

main "$@"

#!/bin/bash

################################################################################
# AWS Secrets Manager Auditor
# Audits secrets: lists secrets, rotation status/dates, rotation Lambda health,
# pending deletion, KMS key usage, last changed/accessed, and upcoming expiry via
# tag/metadata. Pulls CloudWatch metrics (AWS/SecretsManager GetSecretValue
# throttles/errors). Includes env thresholds, logging, Slack/email alerts, and
# saves a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/secrets-manager-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/secrets-manager-auditor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
ROTATION_DAYS_WARN="${ROTATION_DAYS_WARN:-30}"          # warn if last rotation older than this
EXPIRY_DAYS_WARN="${EXPIRY_DAYS_WARN:-30}"              # warn if expiry tag within this window
LAST_ACCESSED_WARN_DAYS="${LAST_ACCESSED_WARN_DAYS:-90}"
THROTTLE_WARN="${THROTTLE_WARN:-5}"                     # throttled GetSecretValue requests
ERROR_WARN="${ERROR_WARN:-1}"                           # failed GetSecretValue requests
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_SECRETS=0
ROTATION_DISABLED=0
ROTATION_OVERDUE=0
PENDING_DELETION=0
NEAR_EXPIRY=0
NO_KMS=0
NO_LAST_ACCESSED=0
STALE_ACCESS=0
THROTTLE_ISSUES=0
ERROR_ISSUES=0
ROTATION_LAMBDA_MISSING=0

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

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
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
      "title": "AWS Secrets Manager Alert",
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
    echo "AWS Secrets Manager Auditor"
    echo "==========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Rotation overdue: > ${ROTATION_DAYS_WARN} days"
    echo "  Expiry window: < ${EXPIRY_DAYS_WARN} days"
    echo "  Last accessed stale: > ${LAST_ACCESSED_WARN_DAYS} days"
    echo "  Throttles warn: >= ${THROTTLE_WARN}"
    echo "  Errors warn: >= ${ERROR_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_secrets() {
  aws_cmd secretsmanager list-secrets \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"SecretList":[]}'
}

describe_secret() {
  local arn="$1"
  aws_cmd secretsmanager describe-secret \
    --secret-id "$arn" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_rotation_lambda_status() {
  local lambda_arn="$1"
  [[ -z "$lambda_arn" || "$lambda_arn" == "null" ]] && return 1
  aws_cmd lambda get-function --function-name "$lambda_arn" --region "${REGION}" >/dev/null 2>&1
}

get_metrics() {
  local operation_metric="$1"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/SecretsManager \
    --metric-name "$operation_metric" \
    --dimensions Name=Operation,Value=GetSecretValue Name=Region,Value="${REGION}" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics Sum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }

days_since() {
  local datestr="$1"
  [[ -z "$datestr" || "$datestr" == "null" ]] && { echo "-1"; return; }
  local ts_now ts_val
  ts_now=$(date +%s)
  ts_val=$(date -d "$datestr" +%s 2>/dev/null || echo "")
  [[ -z "$ts_val" ]] && { echo "-1"; return; }
  echo $(( (ts_now - ts_val) / 86400 ))
}

parse_expiry_tag() {
  local tags_json="$1"
  local expiry
  expiry=$(echo "$tags_json" | jq -r '.[] | select(.Key|ascii_downcase=="expiry_date") | .Value' 2>/dev/null)
  [[ -n "$expiry" && "$expiry" != "null" ]] && { echo "$expiry"; return; }
  expiry=$(echo "$tags_json" | jq -r '.[] | select(.Key|ascii_downcase=="expiration") | .Value' 2>/dev/null)
  [[ -n "$expiry" && "$expiry" != "null" ]] && { echo "$expiry"; return; }
  echo ""
}

analyze_secret() {
  local secret_json="$1"
  local name arn desc kms_arn rotation_enabled last_rotated next_rotation last_changed last_accessed deletion_date tags rotation_lambda
  name=$(echo "$secret_json" | jq_safe '.Name')
  arn=$(echo "$secret_json" | jq_safe '.ARN')
  desc=$(echo "$secret_json" | jq_safe '.Description // ""')
  kms_arn=$(echo "$secret_json" | jq_safe '.KmsKeyId // ""')
  rotation_enabled=$(echo "$secret_json" | jq_safe '.RotationEnabled')
  last_rotated=$(echo "$secret_json" | jq_safe '.LastRotatedDate // ""')
  next_rotation=$(echo "$secret_json" | jq_safe '.NextRotationDate // ""')
  last_changed=$(echo "$secret_json" | jq_safe '.LastChangedDate // ""')
  last_accessed=$(echo "$secret_json" | jq_safe '.LastAccessedDate // ""')
  deletion_date=$(echo "$secret_json" | jq_safe '.DeletedDate // ""')
  rotation_lambda=$(echo "$secret_json" | jq_safe '.RotationLambdaARN // ""')
  tags=$(echo "$secret_json" | jq -c '.Tags // []' 2>/dev/null)

  TOTAL_SECRETS=$((TOTAL_SECRETS + 1))
  log_message INFO "Analyzing secret: ${name}"

  {
    echo "Secret: ${name}"
    echo "  ARN: ${arn}"
    [[ -n "$desc" ]] && echo "  Description: ${desc}"
    echo "  KMS Key: $([[ -n "$kms_arn" && "$kms_arn" != "null" ]] && echo "$kms_arn" || echo default)"
    echo "  Rotation Enabled: ${rotation_enabled}"
    echo "  Rotation Lambda: $([[ -n "$rotation_lambda" && "$rotation_lambda" != "null" ]] && echo "$rotation_lambda" || echo none)"
    echo "  Last Rotated: ${last_rotated:-unknown}"
    echo "  Next Rotation: ${next_rotation:-unknown}"
    echo "  Last Changed: ${last_changed:-unknown}"
    echo "  Last Accessed: ${last_accessed:-unknown}"
  } >> "${OUTPUT_FILE}"

  # Pending deletion
  if [[ -n "$deletion_date" && "$deletion_date" != "null" ]]; then
    ((PENDING_DELETION++))
    printf "  %b⚠️  Pending deletion on %s%b\n" "${YELLOW}" "$deletion_date" "${NC}" >> "${OUTPUT_FILE}"
  fi

  # Rotation
  if [[ "$rotation_enabled" != "true" ]]; then
    ((ROTATION_DISABLED++))
    printf "  %b⚠️  Rotation disabled%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
  if [[ -n "$last_rotated" && "$last_rotated" != "null" ]]; then
    local days_rotated
    days_rotated=$(days_since "$last_rotated")
    if [[ "$days_rotated" -ge "$ROTATION_DAYS_WARN" ]]; then
      ((ROTATION_OVERDUE++))
      printf "  %b⚠️  Rotation overdue (%s days)%b\n" "${YELLOW}" "$days_rotated" "${NC}" >> "${OUTPUT_FILE}"
    fi
  fi
  if [[ -n "$rotation_lambda" && "$rotation_lambda" != "null" ]]; then
    if ! get_rotation_lambda_status "$rotation_lambda"; then
      ((ROTATION_LAMBDA_MISSING++))
      printf "  %b⚠️  Rotation Lambda not found or inaccessible%b\n" "${RED}" "${NC}" >> "${OUTPUT_FILE}"
    fi
  fi

  # KMS
  if [[ -z "$kms_arn" || "$kms_arn" == "null" ]]; then
    ((NO_KMS++))
    printf "  %b⚠️  Using default Secrets Manager key%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi

  # Last accessed
  if [[ -z "$last_accessed" || "$last_accessed" == "null" ]]; then
    ((NO_LAST_ACCESSED++))
    printf "  %b⚠️  No LastAccessedDate available%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  else
    local days_access
    days_access=$(days_since "$last_accessed")
    if [[ "$days_access" -ge "$LAST_ACCESSED_WARN_DAYS" ]]; then
      ((STALE_ACCESS++))
      printf "  %b⚠️  Stale access (%s days since last access)%b\n" "${YELLOW}" "$days_access" "${NC}" >> "${OUTPUT_FILE}"
    fi
  fi

  # Expiry tag
  local expiry_date expiry_days
  expiry_date=$(parse_expiry_tag "$tags")
  if [[ -n "$expiry_date" ]]; then
    local ts_now ts_exp days_to_exp
    ts_now=$(date +%s)
    ts_exp=$(date -d "$expiry_date" +%s 2>/dev/null || echo "")
    if [[ -n "$ts_exp" ]]; then
      days_to_exp=$(( (ts_exp - ts_now) / 86400 ))
      echo "  Expiry (tag): ${expiry_date} (in ${days_to_exp} days)" >> "${OUTPUT_FILE}"
      if [[ "$days_to_exp" -le "$EXPIRY_DAYS_WARN" ]]; then
        ((NEAR_EXPIRY++))
        printf "  %b⚠️  Near expiry within %s days%b\n" "${RED}" "$EXPIRY_DAYS_WARN" "${NC}" >> "${OUTPUT_FILE}"
      fi
    fi
  fi

  # Metrics per secret (operation-scoped metrics are per region/operation, not per secret)
  analyze_metrics

  echo "" >> "${OUTPUT_FILE}"
}

analyze_metrics() {
  echo "  Metrics (${LOOKBACK_HOURS}h, Operation=GetSecretValue):" >> "${OUTPUT_FILE}"
  local throttled_json error_json
  throttled_json=$(get_metrics "ThrottledRequests")
  error_json=$(get_metrics "FailedRequests")
  local throttled_sum error_sum
  throttled_sum=$(echo "$throttled_json" | calculate_sum)
  error_sum=$(echo "$error_json" | calculate_sum)
  echo "    ThrottledRequests: ${throttled_sum}" >> "${OUTPUT_FILE}"
  echo "    FailedRequests: ${error_sum}" >> "${OUTPUT_FILE}"
  if (( $(echo "${throttled_sum} >= ${THROTTLE_WARN}" | bc -l) )); then
    ((THROTTLE_ISSUES++))
    printf "    %b⚠️  Throttling detected%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
  if (( $(echo "${error_sum} >= ${ERROR_WARN}" | bc -l) )); then
    ((ERROR_ISSUES++))
    printf "    %b⚠️  Failed requests detected%b\n" "${RED}" "${NC}" >> "${OUTPUT_FILE}"
  fi
}

summary_section() {
  {
    echo "=== SECRETS SUMMARY ==="
    echo ""
    printf "Total Secrets: %d\n" "${TOTAL_SECRETS}"
    printf "Rotation Disabled: %d\n" "${ROTATION_DISABLED}"
    printf "Rotation Overdue: %d\n" "${ROTATION_OVERDUE}"
    printf "Rotation Lambda Missing: %d\n" "${ROTATION_LAMBDA_MISSING}"
    printf "Pending Deletion: %d\n" "${PENDING_DELETION}"
    printf "Near Expiry (tag): %d\n" "${NEAR_EXPIRY}"
    printf "No Custom KMS: %d\n" "${NO_KMS}"
    printf "Stale Access: %d\n" "${STALE_ACCESS}"
    printf "Throttling Issues: %d\n" "${THROTTLE_ISSUES}"
    printf "Error Issues: %d\n" "${ERROR_ISSUES}"
    echo ""
    if [[ ${THROTTLE_ISSUES} -gt 0 ]] || [[ ${ERROR_ISSUES} -gt 0 ]] || [[ ${NEAR_EXPIRY} -gt 0 ]] || [[ ${ROTATION_OVERDUE} -gt 0 ]]; then
      printf "%b[CRITICAL] Issues detected: throttles/errors/expiry/rotation%b\n" "${RED}" "${NC}"
    elif [[ ${ROTATION_DISABLED} -gt 0 ]] || [[ ${NO_KMS} -gt 0 ]] || [[ ${STALE_ACCESS} -gt 0 ]]; then
      printf "%b[WARNING] Configuration gaps detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Secrets look healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations_section() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${ROTATION_DISABLED} -gt 0 ]] || [[ ${ROTATION_OVERDUE} -gt 0 ]]; then
      echo "Rotation Hygiene:"
      echo "  • Enable rotation for all app secrets"
      echo "  • Set rotation interval to 30/60/90 days per policy"
      echo "  • Ensure rotation Lambda exists and has IAM permissions"
      echo "  • Validate rotation success via CloudWatch Logs"
      echo ""
    fi
    if [[ ${NEAR_EXPIRY} -gt 0 ]]; then
      echo "Expiry Management:"
      echo "  • Renew/replace secrets before expiry"
      echo "  • Automate expiry tags (ExpiryDate)"
      echo "  • Alert on approaching expiry (< ${EXPIRY_DAYS_WARN} days)"
      echo ""
    fi
    if [[ ${THROTTLE_ISSUES} -gt 0 ]] || [[ ${ERROR_ISSUES} -gt 0 ]]; then
      echo "API Reliability:"
      echo "  • Add exponential backoff and jitter for GetSecretValue"
      echo "  • Use caching layer (e.g., in-memory or Envoy SDS)"
      echo "  • Check IAM permissions and network/VPC endpoints"
      echo "  • Monitor CloudWatch metrics for throttles/errors"
      echo ""
    fi
    if [[ ${NO_KMS} -gt 0 ]]; then
      echo "Encryption Controls:"
      echo "  • Use customer-managed KMS keys per app/team"
      echo "  • Restrict KMS key access via key policies"
      echo "  • Enable key rotation if policy allows"
      echo ""
    fi
    if [[ ${STALE_ACCESS} -gt 0 ]]; then
      echo "Access Review:"
      echo "  • Remove unused secrets or rotate before reuse"
      echo "  • Review who/what accesses the secret"
      echo "  • Consider deprecating stale secrets"
      echo ""
    fi
    echo "Observability & Alerts:"
    echo "  • Create CloudWatch alarms on ThrottledRequests/FailedRequests"
    echo "  • Stream Secrets Manager events to EventBridge for alerting"
    echo "  • Send Slack/SNS notifications for rotation failures"
    echo ""
    echo "Best Practices:"
    echo "  • Tag secrets with owner, environment, expiry_date"
    echo "  • Use least-privilege IAM for rotation Lambdas"
    echo "  • Prefer per-service secrets to limit blast radius"
    echo "  • Avoid embedding secrets in code or AMIs"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Secrets Manager Auditor Started ==="
  write_header

  local secrets_json
  secrets_json=$(list_secrets)
  local secrets
  secrets=$(echo "$secrets_json" | jq -c '.SecretList[]?' 2>/dev/null)

  if [[ -z "$secrets" ]]; then
    echo "No secrets found." >> "${OUTPUT_FILE}"
  else
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      analyze_secret "$s"
    done <<< "$secrets"
  fi

  summary_section
  recommendations_section
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Secrets Manager Documentation: https://docs.aws.amazon.com/secretsmanager/latest/userguide/"
  } >> "${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
  log_message INFO "=== Secrets Manager Auditor Completed ==="

  # Alerts
  if [[ ${THROTTLE_ISSUES} -gt 0 ]] || [[ ${ERROR_ISSUES} -gt 0 ]] || [[ ${NEAR_EXPIRY} -gt 0 ]] || [[ ${ROTATION_OVERDUE} -gt 0 ]]; then
    send_slack_alert "🚨 Secrets issues: throttles=${THROTTLE_ISSUES}, errors=${ERROR_ISSUES}, near_expiry=${NEAR_EXPIRY}, rotation_overdue=${ROTATION_OVERDUE}" "CRITICAL"
    send_email_alert "Secrets Manager Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${ROTATION_DISABLED} -gt 0 ]] || [[ ${NO_KMS} -gt 0 ]] || [[ ${STALE_ACCESS} -gt 0 ]]; then
    send_slack_alert "⚠️ Secrets warnings: rotation_disabled=${ROTATION_DISABLED}, no_kms=${NO_KMS}, stale_access=${STALE_ACCESS}" "WARNING"
  fi
}

main "$@"

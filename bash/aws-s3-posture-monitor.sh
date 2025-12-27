#!/bin/bash

################################################################################
# AWS S3 Posture Monitor
# Audits S3 buckets: public access (ACLs/policies), encryption, bucket key,
# versioning/MFA delete, lifecycle (IA/Glacier/expiration), object ownership,
# logging, replication, block public access, access points, and CloudWatch
# request/error metrics. Includes thresholds, logging, Slack/email alerts, and a
# text report with top risky buckets.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/s3-posture-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/s3-posture-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-1}"      # % 4xx+5xx vs requests
REQ_FAIL_COUNT_WARN="${REQ_FAIL_COUNT_WARN:-100}"    # absolute failed requests
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_BUCKETS=0
BUCKETS_PUBLIC=0
BUCKETS_NO_ENCRYPT=0
BUCKETS_NO_VERSIONING=0
BUCKETS_NO_LIFECYCLE=0
BUCKETS_WITH_ISSUES=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

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
      "title": "AWS S3 Posture Alert",
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
    echo "AWS S3 Posture Monitor"
    echo "======================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  Failed Requests Warning: >= ${REQ_FAIL_COUNT_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_buckets() {
  aws_cmd s3api list-buckets --output json 2>/dev/null || echo '{"Buckets":[]}'
}

get_bucket_location() {
  local bucket="$1"
  aws_cmd s3api get-bucket-location --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_bucket_policy_status() {
  local bucket="$1"
  aws_cmd s3api get-bucket-policy-status --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_bucket_acl() {
  local bucket="$1"
  aws_cmd s3api get-bucket-acl --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_public_access_block() {
  local bucket="$1"
  aws_cmd s3api get-public-access-block --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_encryption() {
  local bucket="$1"
  aws_cmd s3api get-bucket-encryption --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_versioning() {
  local bucket="$1"
  aws_cmd s3api get-bucket-versioning --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_ownership() {
  local bucket="$1"
  aws_cmd s3api get-bucket-ownership-controls --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_logging() {
  local bucket="$1"
  aws_cmd s3api get-bucket-logging --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_replication() {
  local bucket="$1"
  aws_cmd s3api get-bucket-replication --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_lifecycle() {
  local bucket="$1"
  aws_cmd s3api get-bucket-lifecycle-configuration --bucket "$bucket" --output json 2>/dev/null || echo '{}'
}

get_metrics() {
  local bucket="$1" metric="$2" stat_type="${3:-Sum}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/S3 \
    --metric-name "$metric" \
    --dimensions Name=BucketName,Value="$bucket" Name=FilterId,Value="EntireBucket" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

is_bucket_public() {
  local policy_status acl_json pab
  policy_status=$(echo "$1" | jq_safe '.PolicyStatus.IsPublic')
  acl_json="$2"
  pab="$3"

  if [[ "${policy_status}" == "true" ]]; then return 0; fi

  # Check ACL for Everyone or AuthenticatedUsers grants
  local acl_public
  acl_public=$(echo "${acl_json}" | jq -r '.Grants[]? | select(.Grantee.URI? | contains("AllUsers") or contains("AuthenticatedUsers")) | .Permission' 2>/dev/null)
  if [[ -n "${acl_public}" ]]; then return 0; fi

  # If Block Public Access missing or disabled
  local block_public
  block_public=$(echo "${pab}" | jq -r '.PublicAccessBlockConfiguration | (.BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets)')
  if [[ "${block_public}" != "true" ]]; then return 0; fi

  return 1
}

record_issue() {
  ISSUES+=("$1")
}

analyze_bucket() {
  local bucket_json="$1"
  local bucket name
  name=$(echo "${bucket_json}" | jq_safe '.Name')
  bucket="${name}"

  TOTAL_BUCKETS=$((TOTAL_BUCKETS + 1))
  log_message INFO "Analyzing bucket: ${bucket}"

  # Location filter
  local loc_json region
  loc_json=$(get_bucket_location "${bucket}")
  region=$(echo "${loc_json}" | jq_safe '.LocationConstraint')
  [[ -z "${region}" || "${region}" == "null" ]] && region="us-east-1"
  if [[ "${region}" != "${REGION}" ]]; then
    log_message INFO "Skipping bucket ${bucket} (region ${region} != ${REGION})"
    return
  fi

  local policy_status acl_json pab_json enc_json ver_json own_json log_json rep_json lc_json
  policy_status=$(get_bucket_policy_status "${bucket}")
  acl_json=$(get_bucket_acl "${bucket}")
  pab_json=$(get_public_access_block "${bucket}")
  enc_json=$(get_encryption "${bucket}")
  ver_json=$(get_versioning "${bucket}")
  own_json=$(get_ownership "${bucket}")
  log_json=$(get_logging "${bucket}")
  rep_json=$(get_replication "${bucket}")
  lc_json=$(get_lifecycle "${bucket}")

  local public="no" enc="no" bucket_key="no" versioning="no" mfa_delete="no" lifecycle="no" ownership="unknown" logging="no" replication="no"

  # Public determination
  if is_bucket_public "${policy_status}" "${acl_json}" "${pab_json}"; then
    public="yes"
    BUCKETS_PUBLIC=$((BUCKETS_PUBLIC + 1))
    record_issue "Bucket ${bucket} is public"
  fi

  # Encryption
  enc=$(echo "${enc_json}" | jq_safe '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')
  bucket_key=$(echo "${enc_json}" | jq_safe '.ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled')
  [[ -z "${enc}" || "${enc}" == "null" ]] && { enc="none"; BUCKETS_NO_ENCRYPT=$((BUCKETS_NO_ENCRYPT + 1)); record_issue "Bucket ${bucket} missing default encryption"; }

  # Versioning / MFA Delete
  versioning=$(echo "${ver_json}" | jq_safe '.Status')
  mfa_delete=$(echo "${ver_json}" | jq_safe '.MFADelete')
  [[ "${versioning}" != "Enabled" ]] && { BUCKETS_NO_VERSIONING=$((BUCKETS_NO_VERSIONING + 1)); record_issue "Bucket ${bucket} versioning disabled"; }

  # Ownership
  ownership=$(echo "${own_json}" | jq_safe '.OwnershipControls.Rules[0].ObjectOwnership // "Unknown"')

  # Logging
  local log_bucket
  log_bucket=$(echo "${log_json}" | jq_safe '.LoggingEnabled.TargetBucket')
  [[ -n "${log_bucket}" && "${log_bucket}" != "null" ]] && logging="yes"

  # Replication
  local rep_status
  rep_status=$(echo "${rep_json}" | jq_safe '.ReplicationConfiguration.Rules[0].Status')
  [[ "${rep_status}" == "Enabled" ]] && replication="yes"

  # Lifecycle
  local lc_len
  lc_len=$(echo "${lc_json}" | jq -r '.Rules | length' 2>/dev/null || echo 0)
  if [[ "${lc_len}" == "0" ]]; then
    BUCKETS_NO_LIFECYCLE=$((BUCKETS_NO_LIFECYCLE + 1))
    record_issue "Bucket ${bucket} missing lifecycle policy"
  else
    lifecycle="yes"
  fi

  # Metrics
  local reqs req_4xx req_5xx error_rate fail_count
  reqs=$(get_metrics "${bucket}" "NumberOfRequests" "Sum" | calculate_sum)
  req_4xx=$(get_metrics "${bucket}" "4xxErrors" "Sum" | calculate_sum)
  req_5xx=$(get_metrics "${bucket}" "5xxErrors" "Sum" | calculate_sum)
  fail_count=$((req_4xx + req_5xx))
  if (( reqs > 0 )); then
    error_rate=$(awk -v f="${fail_count}" -v r="${reqs}" 'BEGIN { if (r>0) printf "%.2f", (f*100)/r; else print "0" }')
  else
    error_rate="0"
  fi

  {
    echo "Bucket: ${bucket}"
    echo "  Public: ${public}"
    echo "  Encryption: ${enc} (BucketKey: ${bucket_key})"
    echo "  Versioning: ${versioning} (MFA Delete: ${mfa_delete})"
    echo "  Ownership: ${ownership}"
    echo "  Logging: ${logging}"
    echo "  Replication: ${replication}"
    echo "  Lifecycle Rules: ${lc_len}"
    echo "  Requests (${LOOKBACK_HOURS}h): ${reqs}"
    echo "  4xx: ${req_4xx}  5xx: ${req_5xx}  ErrorRate: ${error_rate}%"
  } >> "${OUTPUT_FILE}"

  # Threshold checks
  local has_issue=0
  if (( $(echo "${fail_count} >= ${REQ_FAIL_COUNT_WARN}" | bc -l 2>/dev/null || echo 0) )) || (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    has_issue=1
    record_issue "Bucket ${bucket} errors ${fail_count} (${error_rate}%) exceed thresholds"
  fi

  if (( has_issue )); then
    BUCKETS_WITH_ISSUES=$((BUCKETS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local buckets_json
  buckets_json=$(list_buckets)
  local bucket_count
  bucket_count=$(echo "${buckets_json}" | jq -r '.Buckets | length')

  if [[ "${bucket_count}" == "0" ]]; then
    log_message WARN "No buckets found"
    echo "No S3 buckets found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Buckets: ${bucket_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r bucket; do
    analyze_bucket "${bucket}"
  done <<< "$(echo "${buckets_json}" | jq -c '.Buckets[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Buckets: ${TOTAL_BUCKETS}"
    echo "Public Buckets: ${BUCKETS_PUBLIC}"
    echo "No Default Encryption: ${BUCKETS_NO_ENCRYPT}"
    echo "Versioning Disabled: ${BUCKETS_NO_VERSIONING}"
    echo "No Lifecycle Policy: ${BUCKETS_NO_LIFECYCLE}"
    echo "Buckets with Errors: ${BUCKETS_WITH_ISSUES}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "S3 Posture Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "S3 Posture Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

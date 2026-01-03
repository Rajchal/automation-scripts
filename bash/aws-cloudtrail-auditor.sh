#!/bin/bash

################################################################################
# AWS CloudTrail Auditor
# Audits CloudTrail trails for configuration, logging status, and compliance
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/cloudtrail-audit-$(date +%s).txt"
LOG_FILE="/var/log/cloudtrail-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MIN_LOG_AGE_WARN_DAYS="${MIN_LOG_AGE_WARN_DAYS:-7}"

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
list_trails() {
  aws cloudtrail list-trails \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_trails() {
  local trail_names="$1"
  aws cloudtrail describe-trails \
    --region "${REGION}" \
    --trail-name-list ${trail_names} \
    --output json 2>/dev/null || echo '{}'
}

get_trail_status() {
  local trail_arn="$1"
  aws cloudtrail get-trail-status \
    --region "${REGION}" \
    --name "${trail_arn}" \
    --output json 2>/dev/null || echo '{}'
}

get_event_selectors() {
  local trail_arn="$1"
  aws cloudtrail get-event-selectors \
    --region "${REGION}" \
    --trail-name "${trail_arn}" \
    --output json 2>/dev/null || echo '{}'
}

get_insight_selectors() {
  local trail_arn="$1"
  aws cloudtrail get-insight-selectors \
    --region "${REGION}" \
    --trail-name "${trail_arn}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_versioning() {
  local bucket="$1"
  aws s3api get-bucket-versioning \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_encryption() {
  local bucket="$1"
  aws s3api get-bucket-encryption \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

get_bucket_lifecycle() {
  local bucket="$1"
  aws s3api get-bucket-lifecycle-configuration \
    --bucket "${bucket}" \
    --output json 2>/dev/null || echo '{}'
}

list_objects() {
  local bucket="$1"; local prefix="$2"
  aws s3api list-objects-v2 \
    --bucket "${bucket}" \
    --prefix "${prefix}" \
    --max-items 1 \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS CloudTrail Audit Report"
    echo "==========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Min Log Age Warn: ${MIN_LOG_AGE_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_trails() {
  log_message INFO "Auditing CloudTrail trails"
  {
    echo "=== CLOUDTRAIL TRAILS AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local trails_json all_trail_names=()
  trails_json=$(list_trails)
  
  local total_trails=0 multi_region=0 single_region=0 not_logging=0 no_log_validation=0 \
        no_encryption=0 no_cloudwatch=0 s3_issues=0 org_trails=0

  # Collect all trail names
  while IFS= read -r trail_arn; do
    [[ -z "${trail_arn}" || "${trail_arn}" == "null" ]] && continue
    all_trail_names+=("${trail_arn}")
  done < <(echo "${trails_json}" | jq -r '.Trails[]?.TrailARN' 2>/dev/null)

  [[ ${#all_trail_names[@]} -eq 0 ]] && {
    echo "No CloudTrail trails found" >> "${OUTPUT_FILE}"
    return 0
  }

  # Describe all trails at once
  local trail_names_str="${all_trail_names[*]}"
  local trails_details
  trails_details=$(describe_trails "${trail_names_str}")

  echo "${trails_details}" | jq -c '.trailList[]?' 2>/dev/null | while read -r trail; do
    ((total_trails++))
    
    local trail_name trail_arn is_multi_region s3_bucket kms_key_id \
          log_file_validation cloudwatch_logs_group is_org_trail
    trail_name=$(echo "${trail}" | jq_safe '.Name')
    trail_arn=$(echo "${trail}" | jq_safe '.TrailARN')
    is_multi_region=$(echo "${trail}" | jq_safe '.IsMultiRegionTrail')
    s3_bucket=$(echo "${trail}" | jq_safe '.S3BucketName')
    kms_key_id=$(echo "${trail}" | jq_safe '.KmsKeyId')
    log_file_validation=$(echo "${trail}" | jq_safe '.LogFileValidationEnabled')
    cloudwatch_logs_group=$(echo "${trail}" | jq_safe '.CloudWatchLogsLogGroupArn')
    is_org_trail=$(echo "${trail}" | jq_safe '.IsOrganizationTrail')

    {
      echo "Trail: ${trail_name}"
      echo "  ARN: ${trail_arn}"
    } >> "${OUTPUT_FILE}"

    # Multi-region check
    if [[ "${is_multi_region}" == "true" ]]; then
      ((multi_region++))
      echo "  Multi-Region: yes" >> "${OUTPUT_FILE}"
    else
      ((single_region++))
      echo "  Multi-Region: no" >> "${OUTPUT_FILE}"
    fi

    # Organization trail
    if [[ "${is_org_trail}" == "true" ]]; then
      ((org_trails++))
      echo "  Organization Trail: yes" >> "${OUTPUT_FILE}"
    fi

    # Get trail status
    local status
    status=$(get_trail_status "${trail_arn}")
    local is_logging latest_delivery_time
    is_logging=$(echo "${status}" | jq_safe '.IsLogging')
    latest_delivery_time=$(echo "${status}" | jq_safe '.LatestDeliveryTime')

    if [[ "${is_logging}" == "true" ]]; then
      echo "  Logging: active" >> "${OUTPUT_FILE}"
      
      # Check log delivery time
      if [[ -n "${latest_delivery_time}" && "${latest_delivery_time}" != "null" ]]; then
        local delivery_epoch now_epoch days_since
        delivery_epoch=$(date -d "${latest_delivery_time}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        days_since=$(( (now_epoch - delivery_epoch) / 86400 ))
        
        echo "  Last Delivery: ${days_since} days ago" >> "${OUTPUT_FILE}"
        
        if (( days_since >= MIN_LOG_AGE_WARN_DAYS )); then
          ((s3_issues++))
          echo "  WARNING: No log delivery in ${days_since} days" >> "${OUTPUT_FILE}"
        fi
      fi
    else
      ((not_logging++))
      echo "  WARNING: Logging not active" >> "${OUTPUT_FILE}"
    fi

    # S3 bucket audit
    echo "  S3 Bucket: ${s3_bucket}" >> "${OUTPUT_FILE}"
    
    # Check bucket versioning
    local versioning
    versioning=$(get_bucket_versioning "${s3_bucket}")
    local versioning_status
    versioning_status=$(echo "${versioning}" | jq_safe '.Status')
    
    if [[ "${versioning_status}" != "Enabled" ]]; then
      ((s3_issues++))
      echo "  WARNING: S3 bucket versioning not enabled" >> "${OUTPUT_FILE}"
    fi

    # Check bucket encryption
    local encryption
    encryption=$(get_bucket_encryption "${s3_bucket}")
    if [[ -z "${encryption}" || "${encryption}" == "{}" ]]; then
      ((s3_issues++))
      echo "  WARNING: S3 bucket encryption not configured" >> "${OUTPUT_FILE}"
    fi

    # Log file validation
    if [[ "${log_file_validation}" == "true" ]]; then
      echo "  Log Validation: enabled" >> "${OUTPUT_FILE}"
    else
      ((no_log_validation++))
      echo "  WARNING: Log file validation not enabled" >> "${OUTPUT_FILE}"
    fi

    # KMS encryption
    if [[ -n "${kms_key_id}" && "${kms_key_id}" != "null" ]]; then
      echo "  KMS Encryption: enabled" >> "${OUTPUT_FILE}"
    else
      ((no_encryption++))
      echo "  WARNING: KMS encryption not enabled" >> "${OUTPUT_FILE}"
    fi

    # CloudWatch Logs integration
    if [[ -n "${cloudwatch_logs_group}" && "${cloudwatch_logs_group}" != "null" ]]; then
      echo "  CloudWatch Logs: enabled" >> "${OUTPUT_FILE}"
    else
      ((no_cloudwatch++))
      echo "  WARNING: CloudWatch Logs integration not configured" >> "${OUTPUT_FILE}"
    fi

    # Event selectors
    local selectors
    selectors=$(get_event_selectors "${trail_arn}")
    local read_write_type include_mgmt
    read_write_type=$(echo "${selectors}" | jq_safe '.EventSelectors[0].ReadWriteType')
    include_mgmt=$(echo "${selectors}" | jq_safe '.EventSelectors[0].IncludeManagementEvents')
    
    echo "  Event Type: ${read_write_type}" >> "${OUTPUT_FILE}"
    echo "  Management Events: ${include_mgmt}" >> "${OUTPUT_FILE}"

    # Check for data events
    local data_resources
    data_resources=$(echo "${selectors}" | jq '.EventSelectors[0].DataResources' 2>/dev/null)
    if [[ -n "${data_resources}" && "${data_resources}" != "null" && "${data_resources}" != "[]" ]]; then
      echo "  Data Events: configured" >> "${OUTPUT_FILE}"
    fi

    # Insight selectors
    local insights
    insights=$(get_insight_selectors "${trail_arn}")
    local insight_type
    insight_type=$(echo "${insights}" | jq_safe '.InsightSelectors[0].InsightType')
    
    if [[ -n "${insight_type}" && "${insight_type}" != "null" ]]; then
      echo "  CloudTrail Insights: enabled" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Trail Summary:"
    echo "  Total Trails: ${total_trails}"
    echo "  Multi-Region: ${multi_region}"
    echo "  Single-Region: ${single_region}"
    echo "  Organization Trails: ${org_trails}"
    echo ""
    echo "Issues Found:"
    echo "  Not Logging: ${not_logging}"
    echo "  No Log Validation: ${no_log_validation}"
    echo "  No KMS Encryption: ${no_encryption}"
    echo "  No CloudWatch Logs: ${no_cloudwatch}"
    echo "  S3 Configuration Issues: ${s3_issues}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_global_events() {
  log_message INFO "Checking global events logging"
  {
    echo "=== GLOBAL EVENTS LOGGING ==="
  } >> "${OUTPUT_FILE}"

  local trails_json
  trails_json=$(list_trails)
  
  local has_global_events=false
  echo "${trails_json}" | jq -r '.Trails[]?.TrailARN' 2>/dev/null | while read -r trail_arn; do
    [[ -z "${trail_arn}" || "${trail_arn}" == "null" ]] && continue
    
    local trail_details
    trail_details=$(describe_trails "${trail_arn}")
    local include_global
    include_global=$(echo "${trail_details}" | jq_safe '.trailList[0].IncludeGlobalServiceEvents')
    
    if [[ "${include_global}" == "true" ]]; then
      echo "Global events logged by: $(echo "${trail_details}" | jq_safe '.trailList[0].Name')" >> "${OUTPUT_FILE}"
      has_global_events=true
      break
    fi
  done

  if [[ "${has_global_events}" == "false" ]]; then
    echo "WARNING: No trail configured to log global service events" >> "${OUTPUT_FILE}"
  fi
  
  echo "" >> "${OUTPUT_FILE}"
}

audit_log_integrity() {
  log_message INFO "Checking log file integrity validation"
  {
    echo "=== LOG FILE INTEGRITY VALIDATION ==="
  } >> "${OUTPUT_FILE}"

  local trails_json all_trail_names=()
  trails_json=$(list_trails)
  
  while IFS= read -r trail_arn; do
    [[ -z "${trail_arn}" || "${trail_arn}" == "null" ]] && continue
    all_trail_names+=("${trail_arn}")
  done < <(echo "${trails_json}" | jq -r '.Trails[]?.TrailARN' 2>/dev/null)

  [[ ${#all_trail_names[@]} -eq 0 ]] && {
    echo "No trails to validate" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    return 0
  }

  local trail_names_str="${all_trail_names[*]}"
  local trails_details
  trails_details=$(describe_trails "${trail_names_str}")

  local validated=0 not_validated=0
  echo "${trails_details}" | jq -c '.trailList[]?' 2>/dev/null | while read -r trail; do
    local trail_name validation_enabled
    trail_name=$(echo "${trail}" | jq_safe '.Name')
    validation_enabled=$(echo "${trail}" | jq_safe '.LogFileValidationEnabled')
    
    if [[ "${validation_enabled}" == "true" ]]; then
      ((validated++))
      echo "Trail: ${trail_name} - validation enabled" >> "${OUTPUT_FILE}"
    else
      ((not_validated++))
      echo "Trail: ${trail_name} - WARNING: validation disabled" >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo ""
    echo "Validation Summary:"
    echo "  Validated: ${validated}"
    echo "  Not Validated: ${not_validated}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local not_logging="$2"; local no_validation="$3"; local no_encryption="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS CloudTrail Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Total Trails", "value": "${total}", "short": true},
        {"title": "Not Logging", "value": "${not_logging}", "short": true},
        {"title": "No Validation", "value": "${no_validation}", "short": true},
        {"title": "No KMS Encryption", "value": "${no_encryption}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
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
  log_message INFO "Starting CloudTrail audit"
  write_header
  audit_trails
  audit_global_events
  audit_log_integrity
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total not_logging no_validation no_encryption
  total=$(grep "Total Trails:" "${OUTPUT_FILE}" | awk '{print $NF}')
  not_logging=$(grep "Not Logging:" "${OUTPUT_FILE}" | awk '{print $NF}')
  no_validation=$(grep "No Log Validation:" "${OUTPUT_FILE}" | awk '{print $NF}')
  no_encryption=$(grep "No KMS Encryption:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total}" "${not_logging}" "${no_validation}" "${no_encryption}"
  cat "${OUTPUT_FILE}"
}

main "$@"

#!/bin/bash

################################################################################
# AWS CloudWatch Logs Auditor
# Audits CloudWatch log groups for retention policies and encryption
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/cloudwatch-logs-audit-$(date +%s).txt"
LOG_FILE="/var/log/cloudwatch-logs-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
MIN_RETENTION_DAYS="${MIN_RETENTION_DAYS:-30}"
MAX_RETENTION_DAYS="${MAX_RETENTION_DAYS:-365}"

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
describe_log_groups() {
  local next_token="${1:-}"
  local cmd="aws logs describe-log-groups --region ${REGION} --output json"
  [[ -n "${next_token}" ]] && cmd+=" --next-token ${next_token}"
  eval "${cmd}" 2>/dev/null || echo '{}'
}

describe_metric_filters() {
  local log_group="$1"
  aws logs describe-metric-filters \
    --region "${REGION}" \
    --log-group-name "${log_group}" \
    --output json 2>/dev/null || echo '{}'
}

describe_subscription_filters() {
  local log_group="$1"
  aws logs describe-subscription-filters \
    --region "${REGION}" \
    --log-group-name "${log_group}" \
    --output json 2>/dev/null || echo '{}'
}

list_tags_log_group() {
  local log_group="$1"
  aws logs list-tags-log-group \
    --region "${REGION}" \
    --log-group-name "${log_group}" \
    --output json 2>/dev/null || echo '{}'
}

describe_kms_key() {
  local key_id="$1"
  aws kms describe-key \
    --region "${REGION}" \
    --key-id "${key_id}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS CloudWatch Logs Audit Report"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Min Retention: ${MIN_RETENTION_DAYS} days"
    echo "Max Retention: ${MAX_RETENTION_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_log_groups() {
  log_message INFO "Auditing CloudWatch log groups"
  {
    echo "=== CLOUDWATCH LOG GROUPS AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local total_groups=0 no_retention=0 short_retention=0 long_retention=0 \
        encrypted=0 not_encrypted=0 with_metric_filters=0 with_subscriptions=0 \
        empty_groups=0

  local next_token=""
  while true; do
    local log_groups
    log_groups=$(describe_log_groups "${next_token}")
    
    echo "${log_groups}" | jq -c '.logGroups[]?' 2>/dev/null | while read -r group; do
      ((total_groups++))
      
      local log_group_name arn creation_time retention stored_bytes kms_key_id
      log_group_name=$(echo "${group}" | jq_safe '.logGroupName')
      arn=$(echo "${group}" | jq_safe '.arn')
      creation_time=$(echo "${group}" | jq_safe '.creationTime')
      retention=$(echo "${group}" | jq_safe '.retentionInDays')
      stored_bytes=$(echo "${group}" | jq_safe '.storedBytes')
      kms_key_id=$(echo "${group}" | jq_safe '.kmsKeyId')

      {
        echo "Log Group: ${log_group_name}"
        echo "  ARN: ${arn}"
      } >> "${OUTPUT_FILE}"

      # Convert creation time from epoch milliseconds
      if [[ -n "${creation_time}" && "${creation_time}" != "null" ]]; then
        local created_date
        created_date=$(date -d "@$((creation_time / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")
        echo "  Created: ${created_date}" >> "${OUTPUT_FILE}"
      fi

      # Storage size
      if [[ -n "${stored_bytes}" && "${stored_bytes}" != "null" && "${stored_bytes}" != "0" ]]; then
        local stored_mb
        stored_mb=$(echo "scale=2; ${stored_bytes} / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
        echo "  Storage: ${stored_mb} MB" >> "${OUTPUT_FILE}"
      else
        ((empty_groups++))
        echo "  Storage: 0 MB (empty)" >> "${OUTPUT_FILE}"
      fi

      # Retention policy
      if [[ -z "${retention}" || "${retention}" == "null" ]]; then
        ((no_retention++))
        echo "  Retention: Never Expire" >> "${OUTPUT_FILE}"
        echo "  WARNING: No retention policy set (logs never expire)" >> "${OUTPUT_FILE}"
      else
        echo "  Retention: ${retention} days" >> "${OUTPUT_FILE}"
        
        if (( retention < MIN_RETENTION_DAYS )); then
          ((short_retention++))
          echo "  WARNING: Retention below minimum (${MIN_RETENTION_DAYS} days)" >> "${OUTPUT_FILE}"
        elif (( retention > MAX_RETENTION_DAYS )); then
          ((long_retention++))
          echo "  INFO: Retention exceeds ${MAX_RETENTION_DAYS} days" >> "${OUTPUT_FILE}"
        fi
      fi

      # Encryption
      if [[ -n "${kms_key_id}" && "${kms_key_id}" != "null" ]]; then
        ((encrypted++))
        echo "  Encryption: Enabled" >> "${OUTPUT_FILE}"
        echo "  KMS Key: ${kms_key_id}" >> "${OUTPUT_FILE}"
        
        # Get key alias
        local key_details
        key_details=$(describe_kms_key "${kms_key_id}")
        local key_state
        key_state=$(echo "${key_details}" | jq_safe '.KeyMetadata.KeyState')
        
        if [[ "${key_state}" != "Enabled" ]]; then
          echo "  WARNING: KMS key not in Enabled state (${key_state})" >> "${OUTPUT_FILE}"
        fi
      else
        ((not_encrypted++))
        echo "  WARNING: Encryption not enabled" >> "${OUTPUT_FILE}"
      fi

      # Metric filters
      local metric_filters
      metric_filters=$(describe_metric_filters "${log_group_name}")
      local filter_count
      filter_count=$(echo "${metric_filters}" | jq '.metricFilters | length' 2>/dev/null || echo 0)
      
      if (( filter_count > 0 )); then
        ((with_metric_filters++))
        echo "  Metric Filters: ${filter_count}" >> "${OUTPUT_FILE}"
        
        echo "${metric_filters}" | jq -c '.metricFilters[]?' 2>/dev/null | while read -r filter; do
          local filter_name metric_name namespace
          filter_name=$(echo "${filter}" | jq_safe '.filterName')
          metric_name=$(echo "${filter}" | jq_safe '.metricTransformations[0].metricName')
          namespace=$(echo "${filter}" | jq_safe '.metricTransformations[0].metricNamespace')
          echo "    - ${filter_name} -> ${namespace}/${metric_name}" >> "${OUTPUT_FILE}"
        done
      fi

      # Subscription filters
      local subscriptions
      subscriptions=$(describe_subscription_filters "${log_group_name}")
      local sub_count
      sub_count=$(echo "${subscriptions}" | jq '.subscriptionFilters | length' 2>/dev/null || echo 0)
      
      if (( sub_count > 0 )); then
        ((with_subscriptions++))
        echo "  Subscription Filters: ${sub_count}" >> "${OUTPUT_FILE}"
        
        echo "${subscriptions}" | jq -c '.subscriptionFilters[]?' 2>/dev/null | while read -r sub; do
          local sub_name destination
          sub_name=$(echo "${sub}" | jq_safe '.filterName')
          destination=$(echo "${sub}" | jq_safe '.destinationArn')
          echo "    - ${sub_name} -> ${destination}" >> "${OUTPUT_FILE}"
        done
      fi

      # Tags
      local tags
      tags=$(list_tags_log_group "${log_group_name}")
      local tag_count
      tag_count=$(echo "${tags}" | jq '.tags | length' 2>/dev/null || echo 0)
      
      if (( tag_count > 0 )); then
        echo "  Tags: ${tag_count}" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done

    # Check for next token
    next_token=$(echo "${log_groups}" | jq_safe '.nextToken')
    [[ -z "${next_token}" || "${next_token}" == "null" ]] && break
  done

  {
    echo "Log Groups Summary:"
    echo "  Total Groups: ${total_groups}"
    echo "  Empty Groups: ${empty_groups}"
    echo ""
    echo "Retention Policy:"
    echo "  No Retention (Never Expire): ${no_retention}"
    echo "  Below Minimum (< ${MIN_RETENTION_DAYS}d): ${short_retention}"
    echo "  Above Maximum (> ${MAX_RETENTION_DAYS}d): ${long_retention}"
    echo ""
    echo "Encryption:"
    echo "  Encrypted: ${encrypted}"
    echo "  Not Encrypted: ${not_encrypted}"
    echo ""
    echo "Integrations:"
    echo "  With Metric Filters: ${with_metric_filters}"
    echo "  With Subscriptions: ${with_subscriptions}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_log_group_patterns() {
  log_message INFO "Analyzing log group patterns"
  {
    echo "=== LOG GROUP PATTERNS ==="
  } >> "${OUTPUT_FILE}"

  local next_token=""
  local lambda_logs=0 ecs_logs=0 rds_logs=0 eks_logs=0 apigw_logs=0 vpc_logs=0 other_logs=0

  while true; do
    local log_groups
    log_groups=$(describe_log_groups "${next_token}")
    
    while IFS= read -r log_group_name; do
      [[ -z "${log_group_name}" || "${log_group_name}" == "null" ]] && continue
      
      case "${log_group_name}" in
        /aws/lambda/*)
          ((lambda_logs++))
          ;;
        /ecs/*)
          ((ecs_logs++))
          ;;
        /aws/rds/*)
          ((rds_logs++))
          ;;
        /aws/eks/*)
          ((eks_logs++))
          ;;
        /aws/apigateway/*)
          ((apigw_logs++))
          ;;
        /aws/vpc/*)
          ((vpc_logs++))
          ;;
        *)
          ((other_logs++))
          ;;
      esac
    done < <(echo "${log_groups}" | jq -r '.logGroups[]?.logGroupName' 2>/dev/null)

    next_token=$(echo "${log_groups}" | jq_safe '.nextToken')
    [[ -z "${next_token}" || "${next_token}" == "null" ]] && break
  done

  {
    echo "Log Groups by Service:"
    echo "  Lambda: ${lambda_logs}"
    echo "  ECS: ${ecs_logs}"
    echo "  RDS: ${rds_logs}"
    echo "  EKS: ${eks_logs}"
    echo "  API Gateway: ${apigw_logs}"
    echo "  VPC: ${vpc_logs}"
    echo "  Other: ${other_logs}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_high_volume_groups() {
  log_message INFO "Checking high-volume log groups"
  {
    echo "=== HIGH-VOLUME LOG GROUPS ==="
  } >> "${OUTPUT_FILE}"

  local high_volume_threshold=$((1024 * 1024 * 1024))  # 1 GB in bytes
  local high_volume_count=0

  local next_token=""
  while true; do
    local log_groups
    log_groups=$(describe_log_groups "${next_token}")
    
    echo "${log_groups}" | jq -c '.logGroups[]?' 2>/dev/null | while read -r group; do
      local log_group_name stored_bytes
      log_group_name=$(echo "${group}" | jq_safe '.logGroupName')
      stored_bytes=$(echo "${group}" | jq_safe '.storedBytes')

      if [[ -n "${stored_bytes}" && "${stored_bytes}" != "null" && "${stored_bytes}" != "0" ]]; then
        if (( stored_bytes >= high_volume_threshold )); then
          ((high_volume_count++))
          local stored_gb
          stored_gb=$(echo "scale=2; ${stored_bytes} / 1024 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
          {
            echo "Log Group: ${log_group_name}"
            echo "  Storage: ${stored_gb} GB"
            echo ""
          } >> "${OUTPUT_FILE}"
        fi
      fi
    done

    next_token=$(echo "${log_groups}" | jq_safe '.nextToken')
    [[ -z "${next_token}" || "${next_token}" == "null" ]] && break
  done

  if (( high_volume_count == 0 )); then
    echo "No high-volume log groups found (> 1 GB)" >> "${OUTPUT_FILE}"
  else
    echo "Total high-volume groups: ${high_volume_count}" >> "${OUTPUT_FILE}"
  fi
  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local no_retention="$2"; local not_encrypted="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS CloudWatch Logs Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Total Groups", "value": "${total}", "short": true},
        {"title": "No Retention", "value": "${no_retention}", "short": true},
        {"title": "Not Encrypted", "value": "${not_encrypted}", "short": true},
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
  log_message INFO "Starting CloudWatch Logs audit"
  write_header
  audit_log_groups
  analyze_log_group_patterns
  check_high_volume_groups
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total no_retention not_encrypted
  total=$(grep "Total Groups:" "${OUTPUT_FILE}" | awk '{print $NF}')
  no_retention=$(grep "No Retention (Never Expire):" "${OUTPUT_FILE}" | awk '{print $NF}')
  not_encrypted=$(grep "Not Encrypted:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total}" "${no_retention}" "${not_encrypted}"
  cat "${OUTPUT_FILE}"
}

main "$@"

#!/bin/bash

################################################################################
# AWS Config Rules Auditor
# Audits AWS Config rules compliance status and configuration
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/config-rules-audit-$(date +%s).txt"
LOG_FILE="/var/log/config-rules-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

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
describe_configuration_recorder_status() {
  aws configservice describe-configuration-recorder-status \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_configuration_recorders() {
  aws configservice describe-configuration-recorders \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_delivery_channels() {
  aws configservice describe-delivery-channels \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_delivery_channel_status() {
  aws configservice describe-delivery-channel-status \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_config_rules() {
  aws configservice describe-config-rules \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_compliance_by_config_rule() {
  aws configservice describe-compliance-by-config-rule \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_compliance_details_by_config_rule() {
  local rule_name="$1"
  aws configservice get-compliance-details-by-config-rule \
    --region "${REGION}" \
    --config-rule-name "${rule_name}" \
    --compliance-types NON_COMPLIANT \
    --limit 100 \
    --output json 2>/dev/null || echo '{}'
}

describe_remediation_configurations() {
  local rule_names="$1"
  aws configservice describe-remediation-configurations \
    --region "${REGION}" \
    --config-rule-names ${rule_names} \
    --output json 2>/dev/null || echo '{}'
}

describe_organization_config_rules() {
  aws configservice describe-organization-config-rules \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_organization_config_rule_detailed_status() {
  local rule_name="$1"
  aws configservice get-organization-config-rule-detailed-status \
    --region "${REGION}" \
    --organization-config-rule-name "${rule_name}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Config Rules Audit Report"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_configuration_recorder() {
  log_message INFO "Auditing Config recorder status"
  {
    echo "=== CONFIGURATION RECORDER STATUS ==="
  } >> "${OUTPUT_FILE}"

  local recorder_status recorder_config
  recorder_status=$(describe_configuration_recorder_status)
  recorder_config=$(describe_configuration_recorders)

  local has_recorder=false
  echo "${recorder_status}" | jq -c '.ConfigurationRecordersStatus[]?' 2>/dev/null | while read -r recorder; do
    has_recorder=true
    local name recording last_status last_start last_stop
    name=$(echo "${recorder}" | jq_safe '.name')
    recording=$(echo "${recorder}" | jq_safe '.recording')
    last_status=$(echo "${recorder}" | jq_safe '.lastStatus')
    last_start=$(echo "${recorder}" | jq_safe '.lastStartTime')
    last_stop=$(echo "${recorder}" | jq_safe '.lastStopTime')

    {
      echo "Recorder: ${name}"
      echo "  Recording: ${recording}"
      echo "  Last Status: ${last_status}"
    } >> "${OUTPUT_FILE}"

    if [[ "${recording}" != "true" ]]; then
      echo "  WARNING: Configuration recorder not recording" >> "${OUTPUT_FILE}"
    fi

    if [[ "${last_status}" != "SUCCESS" ]]; then
      echo "  WARNING: Last recording status was ${last_status}" >> "${OUTPUT_FILE}"
    fi

    if [[ -n "${last_start}" && "${last_start}" != "null" ]]; then
      echo "  Last Start: ${last_start}" >> "${OUTPUT_FILE}"
    fi

    # Get recorder configuration
    local recorder_details
    recorder_details=$(echo "${recorder_config}" | jq -c --arg name "${name}" '.ConfigurationRecorders[]? | select(.name == $name)' 2>/dev/null)
    if [[ -n "${recorder_details}" ]]; then
      local all_supported include_global
      all_supported=$(echo "${recorder_details}" | jq_safe '.recordingGroup.allSupported')
      include_global=$(echo "${recorder_details}" | jq_safe '.recordingGroup.includeGlobalResourceTypes')
      
      echo "  All Resources: ${all_supported}" >> "${OUTPUT_FILE}"
      echo "  Global Resources: ${include_global}" >> "${OUTPUT_FILE}"

      if [[ "${all_supported}" != "true" ]]; then
        echo "  WARNING: Not recording all supported resource types" >> "${OUTPUT_FILE}"
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  if [[ "${has_recorder}" == "false" ]]; then
    {
      echo "WARNING: No configuration recorder found"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
}

audit_delivery_channel() {
  log_message INFO "Auditing Config delivery channel"
  {
    echo "=== DELIVERY CHANNEL STATUS ==="
  } >> "${OUTPUT_FILE}"

  local channel_status channels
  channel_status=$(describe_delivery_channel_status)
  channels=$(describe_delivery_channels)

  local has_channel=false
  echo "${channel_status}" | jq -c '.DeliveryChannelsStatus[]?' 2>/dev/null | while read -r channel; do
    has_channel=true
    local name last_config_snapshot last_config_history last_stream
    name=$(echo "${channel}" | jq_safe '.name')
    last_config_snapshot=$(echo "${channel}" | jq_safe '.configSnapshotDeliveryInfo.lastStatus')
    last_config_history=$(echo "${channel}" | jq_safe '.configHistoryDeliveryInfo.lastStatus')
    last_stream=$(echo "${channel}" | jq_safe '.configStreamDeliveryInfo.lastStatus')

    {
      echo "Channel: ${name}"
      echo "  Snapshot Status: ${last_config_snapshot}"
      echo "  History Status: ${last_config_history}"
      echo "  Stream Status: ${last_stream}"
    } >> "${OUTPUT_FILE}"

    if [[ "${last_config_snapshot}" != "SUCCESS" && "${last_config_snapshot}" != "Not Applicable" ]]; then
      echo "  WARNING: Snapshot delivery status is ${last_config_snapshot}" >> "${OUTPUT_FILE}"
    fi

    if [[ "${last_config_history}" != "SUCCESS" ]]; then
      echo "  WARNING: History delivery status is ${last_config_history}" >> "${OUTPUT_FILE}"
    fi

    # Get channel configuration
    local channel_details
    channel_details=$(echo "${channels}" | jq -c --arg name "${name}" '.DeliveryChannels[]? | select(.name == $name)' 2>/dev/null)
    if [[ -n "${channel_details}" ]]; then
      local s3_bucket sns_topic delivery_freq
      s3_bucket=$(echo "${channel_details}" | jq_safe '.s3BucketName')
      sns_topic=$(echo "${channel_details}" | jq_safe '.snsTopicARN')
      delivery_freq=$(echo "${channel_details}" | jq_safe '.configSnapshotDeliveryProperties.deliveryFrequency')
      
      echo "  S3 Bucket: ${s3_bucket}" >> "${OUTPUT_FILE}"
      if [[ -n "${sns_topic}" && "${sns_topic}" != "null" ]]; then
        echo "  SNS Topic: ${sns_topic}" >> "${OUTPUT_FILE}"
      fi
      if [[ -n "${delivery_freq}" && "${delivery_freq}" != "null" ]]; then
        echo "  Delivery Frequency: ${delivery_freq}" >> "${OUTPUT_FILE}"
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  if [[ "${has_channel}" == "false" ]]; then
    {
      echo "WARNING: No delivery channel found"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
}

audit_config_rules() {
  log_message INFO "Auditing Config rules"
  {
    echo "=== CONFIG RULES AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local rules_json compliance_json
  rules_json=$(describe_config_rules)
  compliance_json=$(describe_compliance_by_config_rule)

  local total_rules=0 compliant=0 non_compliant=0 insufficient_data=0 not_applicable=0 \
        managed_rules=0 custom_rules=0 with_remediation=0

  echo "${rules_json}" | jq -c '.ConfigRules[]?' 2>/dev/null | while read -r rule; do
    ((total_rules++))
    
    local rule_name rule_arn rule_id source_identifier input_params
    rule_name=$(echo "${rule}" | jq_safe '.ConfigRuleName')
    rule_arn=$(echo "${rule}" | jq_safe '.ConfigRuleArn')
    rule_id=$(echo "${rule}" | jq_safe '.ConfigRuleId')
    source_identifier=$(echo "${rule}" | jq_safe '.Source.SourceIdentifier')
    input_params=$(echo "${rule}" | jq_safe '.InputParameters')

    {
      echo "Rule: ${rule_name}"
      echo "  ID: ${rule_id}"
    } >> "${OUTPUT_FILE}"

    # Check if managed or custom
    local source_owner
    source_owner=$(echo "${rule}" | jq_safe '.Source.Owner')
    if [[ "${source_owner}" == "AWS" ]]; then
      ((managed_rules++))
      echo "  Type: AWS Managed" >> "${OUTPUT_FILE}"
      echo "  Identifier: ${source_identifier}" >> "${OUTPUT_FILE}"
    else
      ((custom_rules++))
      echo "  Type: Custom" >> "${OUTPUT_FILE}"
    fi

    # Get compliance status
    local compliance_status compliance_type
    compliance_status=$(echo "${compliance_json}" | jq -c --arg name "${rule_name}" '.ComplianceByConfigRules[]? | select(.ConfigRuleName == $name)' 2>/dev/null)
    compliance_type=$(echo "${compliance_status}" | jq_safe '.Compliance.ComplianceType')

    case "${compliance_type}" in
      "COMPLIANT")
        ((compliant++))
        echo "  Compliance: COMPLIANT" >> "${OUTPUT_FILE}"
        ;;
      "NON_COMPLIANT")
        ((non_compliant++))
        echo "  Compliance: NON_COMPLIANT" >> "${OUTPUT_FILE}"
        
        # Get non-compliant resources
        local details
        details=$(get_compliance_details_by_config_rule "${rule_name}")
        local non_compliant_count
        non_compliant_count=$(echo "${details}" | jq '.EvaluationResults | length' 2>/dev/null || echo 0)
        
        if (( non_compliant_count > 0 )); then
          echo "  Non-Compliant Resources: ${non_compliant_count}" >> "${OUTPUT_FILE}"
          
          # Show first few non-compliant resources
          echo "${details}" | jq -c '.EvaluationResults[]?' 2>/dev/null | head -5 | while read -r result; do
            local resource_type resource_id
            resource_type=$(echo "${result}" | jq_safe '.EvaluationResultIdentifier.EvaluationResultQualifier.ResourceType')
            resource_id=$(echo "${result}" | jq_safe '.EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId')
            echo "    - ${resource_type}: ${resource_id}" >> "${OUTPUT_FILE}"
          done
          
          if (( non_compliant_count > 5 )); then
            echo "    ... and $((non_compliant_count - 5)) more" >> "${OUTPUT_FILE}"
          fi
        fi
        ;;
      "INSUFFICIENT_DATA")
        ((insufficient_data++))
        echo "  Compliance: INSUFFICIENT_DATA" >> "${OUTPUT_FILE}"
        ;;
      "NOT_APPLICABLE")
        ((not_applicable++))
        echo "  Compliance: NOT_APPLICABLE" >> "${OUTPUT_FILE}"
        ;;
      *)
        echo "  Compliance: ${compliance_type}" >> "${OUTPUT_FILE}"
        ;;
    esac

    # Check for automatic remediation
    local remediation
    remediation=$(describe_remediation_configurations "${rule_name}")
    local has_remediation
    has_remediation=$(echo "${remediation}" | jq '.RemediationConfigurations | length' 2>/dev/null || echo 0)
    
    if (( has_remediation > 0 )); then
      ((with_remediation++))
      local auto_enabled target_id
      auto_enabled=$(echo "${remediation}" | jq_safe '.RemediationConfigurations[0].Automatic')
      target_id=$(echo "${remediation}" | jq_safe '.RemediationConfigurations[0].TargetIdentifier')
      
      echo "  Remediation: configured" >> "${OUTPUT_FILE}"
      echo "    Automatic: ${auto_enabled}" >> "${OUTPUT_FILE}"
      echo "    Target: ${target_id}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Config Rules Summary:"
    echo "  Total Rules: ${total_rules}"
    echo "  Managed Rules: ${managed_rules}"
    echo "  Custom Rules: ${custom_rules}"
    echo "  With Remediation: ${with_remediation}"
    echo ""
    echo "Compliance Status:"
    echo "  Compliant: ${compliant}"
    echo "  Non-Compliant: ${non_compliant}"
    echo "  Insufficient Data: ${insufficient_data}"
    echo "  Not Applicable: ${not_applicable}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_organization_rules() {
  log_message INFO "Auditing organization config rules"
  {
    echo "=== ORGANIZATION CONFIG RULES ==="
  } >> "${OUTPUT_FILE}"

  local org_rules
  org_rules=$(describe_organization_config_rules)

  local has_org_rules=false
  local total_org_rules=0
  echo "${org_rules}" | jq -c '.OrganizationConfigRules[]?' 2>/dev/null | while read -r rule; do
    has_org_rules=true
    ((total_org_rules++))
    
    local rule_name rule_arn
    rule_name=$(echo "${rule}" | jq_safe '.OrganizationConfigRuleName')
    rule_arn=$(echo "${rule}" | jq_safe '.OrganizationConfigRuleArn')

    {
      echo "Organization Rule: ${rule_name}"
      echo "  ARN: ${rule_arn}"
    } >> "${OUTPUT_FILE}"

    # Get detailed status
    local status
    status=$(get_organization_config_rule_detailed_status "${rule_name}")
    local succeeded failed
    succeeded=$(echo "${status}" | jq '[.OrganizationConfigRuleDetailedStatus[]? | select(.Status == "CREATE_SUCCESSFUL" or .Status == "UPDATE_SUCCESSFUL")] | length' 2>/dev/null || echo 0)
    failed=$(echo "${status}" | jq '[.OrganizationConfigRuleDetailedStatus[]? | select(.Status == "CREATE_FAILED" or .Status == "UPDATE_FAILED")] | length' 2>/dev/null || echo 0)

    echo "  Succeeded: ${succeeded}" >> "${OUTPUT_FILE}"
    if (( failed > 0 )); then
      echo "  WARNING: Failed: ${failed}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  if [[ "${has_org_rules}" == "false" ]]; then
    {
      echo "No organization config rules found"
      echo ""
    } >> "${OUTPUT_FILE}"
  else
    {
      echo "Organization Rules Summary:"
      echo "  Total: ${total_org_rules}"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
}

send_slack_alert() {
  local total="$1"; local non_compliant="$2"; local insufficient="$3"; local with_remediation="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Config Rules Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Total Rules", "value": "${total}", "short": true},
        {"title": "Non-Compliant", "value": "${non_compliant}", "short": true},
        {"title": "Insufficient Data", "value": "${insufficient}", "short": true},
        {"title": "With Remediation", "value": "${with_remediation}", "short": true},
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
  log_message INFO "Starting AWS Config rules audit"
  write_header
  audit_configuration_recorder
  audit_delivery_channel
  audit_config_rules
  audit_organization_rules
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total non_compliant insufficient with_remediation
  total=$(grep "Total Rules:" "${OUTPUT_FILE}" | awk '{print $NF}')
  non_compliant=$(grep "Non-Compliant:" "${OUTPUT_FILE}" | awk '{print $NF}')
  insufficient=$(grep "Insufficient Data:" "${OUTPUT_FILE}" | awk '{print $NF}')
  with_remediation=$(grep "With Remediation:" "${OUTPUT_FILE}" | awk '{print $NF}')
  send_slack_alert "${total}" "${non_compliant}" "${insufficient}" "${with_remediation}"
  cat "${OUTPUT_FILE}"
}

main "$@"

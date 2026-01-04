#!/bin/bash

################################################################################
# AWS GuardDuty Findings Monitor
# Monitors GuardDuty findings by severity and type
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/guardduty-findings-$(date +%s).txt"
LOG_FILE="/var/log/guardduty-findings.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
CRITICAL_SEVERITY="${CRITICAL_SEVERITY:-7.0}"
HIGH_SEVERITY="${HIGH_SEVERITY:-4.0}"

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
list_detectors() {
  aws guardduty list-detectors \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_detector() {
  local detector_id="$1"
  aws guardduty get-detector \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --output json 2>/dev/null || echo '{}'
}

list_findings() {
  local detector_id="$1"
  local finding_criteria="$2"
  aws guardduty list-findings \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --finding-criteria "${finding_criteria}" \
    --max-results 50 \
    --output json 2>/dev/null || echo '{}'
}

get_findings() {
  local detector_id="$1"; shift
  local finding_ids="$@"
  [[ -z "${finding_ids}" ]] && echo '{}' && return
  aws guardduty get-findings \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --finding-ids ${finding_ids} \
    --output json 2>/dev/null || echo '{}'
}

get_master_account() {
  local detector_id="$1"
  aws guardduty get-master-account \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --output json 2>/dev/null || echo '{}'
}

list_members() {
  local detector_id="$1"
  aws guardduty list-members \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --output json 2>/dev/null || echo '{}'
}

get_threat_intel_set() {
  local detector_id="$1"; local set_id="$2"
  aws guardduty get-threat-intel-set \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --threat-intel-set-id "${set_id}" \
    --output json 2>/dev/null || echo '{}'
}

list_threat_intel_sets() {
  local detector_id="$1"
  aws guardduty list-threat-intel-sets \
    --region "${REGION}" \
    --detector-id "${detector_id}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS GuardDuty Findings Report"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${LOOKBACK_HOURS} hours"
    echo "Critical Severity: >= ${CRITICAL_SEVERITY}"
    echo "High Severity: >= ${HIGH_SEVERITY}"
    echo ""
  } > "${OUTPUT_FILE}"
}

monitor_detector_status() {
  log_message INFO "Checking GuardDuty detector status"
  {
    echo "=== GUARDDUTY DETECTOR STATUS ==="
  } >> "${OUTPUT_FILE}"

  local detectors
  detectors=$(list_detectors)
  
  local detector_ids
  detector_ids=$(echo "${detectors}" | jq -r '.DetectorIds[]?' 2>/dev/null)
  
  if [[ -z "${detector_ids}" ]]; then
    {
      echo "WARNING: No GuardDuty detector found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return 0
  fi

  echo "${detector_ids}" | while read -r detector_id; do
    [[ -z "${detector_id}" ]] && continue
    
    local detector
    detector=$(get_detector "${detector_id}")
    
    local status service_role created finding_frequency
    status=$(echo "${detector}" | jq_safe '.Status')
    service_role=$(echo "${detector}" | jq_safe '.ServiceRole')
    created=$(echo "${detector}" | jq_safe '.CreatedAt')
    finding_frequency=$(echo "${detector}" | jq_safe '.FindingPublishingFrequency')

    {
      echo "Detector: ${detector_id}"
      echo "  Status: ${status}"
      echo "  Service Role: ${service_role}"
      echo "  Created: ${created}"
      echo "  Finding Frequency: ${finding_frequency}"
    } >> "${OUTPUT_FILE}"

    if [[ "${status}" != "ENABLED" ]]; then
      echo "  WARNING: Detector not enabled" >> "${OUTPUT_FILE}"
    fi

    # Check data sources
    local s3_logs dns_logs flow_logs k8s_audit_logs
    s3_logs=$(echo "${detector}" | jq_safe '.DataSources.S3Logs.Status')
    dns_logs=$(echo "${detector}" | jq_safe '.DataSources.DNSLogs.Status')
    flow_logs=$(echo "${detector}" | jq_safe '.DataSources.FlowLogs.Status')
    k8s_audit_logs=$(echo "${detector}" | jq_safe '.DataSources.Kubernetes.AuditLogs.Status')

    {
      echo "  Data Sources:"
      echo "    S3 Logs: ${s3_logs}"
      echo "    DNS Logs: ${dns_logs}"
      echo "    Flow Logs: ${flow_logs}"
      echo "    K8s Audit Logs: ${k8s_audit_logs}"
    } >> "${OUTPUT_FILE}"

    # Check for master account
    local master
    master=$(get_master_account "${detector_id}")
    local master_account
    master_account=$(echo "${master}" | jq_safe '.Master.AccountId')
    
    if [[ -n "${master_account}" && "${master_account}" != "null" ]]; then
      echo "  Master Account: ${master_account}" >> "${OUTPUT_FILE}"
    fi

    # Check for member accounts
    local members
    members=$(list_members "${detector_id}")
    local member_count
    member_count=$(echo "${members}" | jq '.Members | length' 2>/dev/null || echo 0)
    
    if (( member_count > 0 )); then
      echo "  Member Accounts: ${member_count}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

monitor_findings() {
  log_message INFO "Monitoring GuardDuty findings"
  {
    echo "=== GUARDDUTY FINDINGS (Last ${LOOKBACK_HOURS}h) ==="
  } >> "${OUTPUT_FILE}"

  local detectors
  detectors=$(list_detectors)
  
  local detector_ids
  detector_ids=$(echo "${detectors}" | jq -r '.DetectorIds[]?' 2>/dev/null)
  
  if [[ -z "${detector_ids}" ]]; then
    echo "No detector found" >> "${OUTPUT_FILE}"
    return 0
  fi

  local total_findings=0 critical_findings=0 high_findings=0 medium_findings=0 low_findings=0

  echo "${detector_ids}" | while read -r detector_id; do
    [[ -z "${detector_id}" ]] && continue

    # Calculate timestamp for lookback period
    local lookback_epoch
    lookback_epoch=$(date -d "${LOOKBACK_HOURS} hours ago" +%s)000
    local now_epoch
    now_epoch=$(date +%s)000

    # Build finding criteria
    local criteria
    criteria=$(cat <<EOF
{
  "Criterion": {
    "updatedAt": {
      "Gte": ${lookback_epoch},
      "Lte": ${now_epoch}
    }
  }
}
EOF
)

    local findings_list finding_ids=()
    findings_list=$(list_findings "${detector_id}" "${criteria}")
    
    while IFS= read -r finding_id; do
      [[ -z "${finding_id}" || "${finding_id}" == "null" ]] && continue
      finding_ids+=("${finding_id}")
    done < <(echo "${findings_list}" | jq -r '.FindingIds[]?' 2>/dev/null)

    if [[ ${#finding_ids[@]} -eq 0 ]]; then
      echo "No findings in the last ${LOOKBACK_HOURS} hours" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    total_findings=${#finding_ids[@]}

    # Get finding details
    local findings_details
    findings_details=$(get_findings "${detector_id}" "${finding_ids[@]}")

    echo "${findings_details}" | jq -c '.Findings[]?' 2>/dev/null | while read -r finding; do
      local finding_id finding_type severity title description created updated
      finding_id=$(echo "${finding}" | jq_safe '.Id')
      finding_type=$(echo "${finding}" | jq_safe '.Type')
      severity=$(echo "${finding}" | jq_safe '.Severity')
      title=$(echo "${finding}" | jq_safe '.Title')
      description=$(echo "${finding}" | jq_safe '.Description')
      created=$(echo "${finding}" | jq_safe '.CreatedAt')
      updated=$(echo "${finding}" | jq_safe '.UpdatedAt')

      # Categorize by severity
      if (( $(echo "${severity} >= ${CRITICAL_SEVERITY}" | bc -l) )); then
        ((critical_findings++))
      elif (( $(echo "${severity} >= ${HIGH_SEVERITY}" | bc -l) )); then
        ((high_findings++))
      elif (( $(echo "${severity} >= 1.0" | bc -l) )); then
        ((medium_findings++))
      else
        ((low_findings++))
      fi

      {
        echo "Finding ID: ${finding_id}"
        echo "  Type: ${finding_type}"
        echo "  Severity: ${severity}"
        echo "  Title: ${title}"
      } >> "${OUTPUT_FILE}"

      # Resource information
      local resource_type
      resource_type=$(echo "${finding}" | jq_safe '.Resource.ResourceType')
      
      case "${resource_type}" in
        "Instance")
          local instance_id
          instance_id=$(echo "${finding}" | jq_safe '.Resource.InstanceDetails.InstanceId')
          echo "  Resource: EC2 Instance ${instance_id}" >> "${OUTPUT_FILE}"
          ;;
        "AccessKey")
          local username
          username=$(echo "${finding}" | jq_safe '.Resource.AccessKeyDetails.UserName')
          echo "  Resource: IAM Access Key (User: ${username})" >> "${OUTPUT_FILE}"
          ;;
        "S3Bucket")
          local bucket_name
          bucket_name=$(echo "${finding}" | jq_safe '.Resource.S3BucketDetails[0].Name')
          echo "  Resource: S3 Bucket ${bucket_name}" >> "${OUTPUT_FILE}"
          ;;
        "EKSCluster")
          local cluster_name
          cluster_name=$(echo "${finding}" | jq_safe '.Resource.EksClusterDetails.Name')
          echo "  Resource: EKS Cluster ${cluster_name}" >> "${OUTPUT_FILE}"
          ;;
        *)
          echo "  Resource Type: ${resource_type}" >> "${OUTPUT_FILE}"
          ;;
      esac

      {
        echo "  Created: ${created}"
        echo "  Updated: ${updated}"
      } >> "${OUTPUT_FILE}"

      # Show action information if available
      local action_type
      action_type=$(echo "${finding}" | jq_safe '.Service.Action.ActionType')
      if [[ -n "${action_type}" && "${action_type}" != "null" ]]; then
        echo "  Action: ${action_type}" >> "${OUTPUT_FILE}"
      fi

      # Show archived status
      local archived
      archived=$(echo "${finding}" | jq_safe '.Service.Archived')
      if [[ "${archived}" == "true" ]]; then
        echo "  Status: Archived" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Findings Summary:"
    echo "  Total: ${total_findings}"
    echo "  Critical (>= ${CRITICAL_SEVERITY}): ${critical_findings}"
    echo "  High (>= ${HIGH_SEVERITY}): ${high_findings}"
    echo "  Medium: ${medium_findings}"
    echo "  Low: ${low_findings}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

audit_threat_intel() {
  log_message INFO "Auditing threat intelligence sets"
  {
    echo "=== THREAT INTELLIGENCE SETS ==="
  } >> "${OUTPUT_FILE}"

  local detectors
  detectors=$(list_detectors)
  
  local detector_ids
  detector_ids=$(echo "${detectors}" | jq -r '.DetectorIds[]?' 2>/dev/null)
  
  if [[ -z "${detector_ids}" ]]; then
    echo "No detector found" >> "${OUTPUT_FILE}"
    return 0
  fi

  local has_threat_intel=false
  echo "${detector_ids}" | while read -r detector_id; do
    [[ -z "${detector_id}" ]] && continue

    local threat_sets
    threat_sets=$(list_threat_intel_sets "${detector_id}")
    
    local set_ids
    set_ids=$(echo "${threat_sets}" | jq -r '.ThreatIntelSetIds[]?' 2>/dev/null)
    
    if [[ -z "${set_ids}" ]]; then
      continue
    fi

    has_threat_intel=true
    echo "${set_ids}" | while read -r set_id; do
      [[ -z "${set_id}" ]] && continue
      
      local set_details
      set_details=$(get_threat_intel_set "${detector_id}" "${set_id}")
      
      local name format location status
      name=$(echo "${set_details}" | jq_safe '.Name')
      format=$(echo "${set_details}" | jq_safe '.Format')
      location=$(echo "${set_details}" | jq_safe '.Location')
      status=$(echo "${set_details}" | jq_safe '.Status')

      {
        echo "Threat Intel Set: ${name}"
        echo "  ID: ${set_id}"
        echo "  Format: ${format}"
        echo "  Location: ${location}"
        echo "  Status: ${status}"
        echo ""
      } >> "${OUTPUT_FILE}"
    done
  done

  if [[ "${has_threat_intel}" == "false" ]]; then
    {
      echo "No threat intelligence sets configured"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
}

send_slack_alert() {
  local total="$1"; local critical="$2"; local high="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  
  local color="good"
  (( critical > 0 )) && color="danger"
  (( high > 0 && critical == 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS GuardDuty Findings Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Findings", "value": "${total}", "short": true},
        {"title": "Critical", "value": "${critical}", "short": true},
        {"title": "High", "value": "${high}", "short": true},
        {"title": "Lookback", "value": "${LOOKBACK_HOURS}h", "short": true},
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
  log_message INFO "Starting GuardDuty findings monitor"
  write_header
  monitor_detector_status
  monitor_findings
  audit_threat_intel
  log_message INFO "Monitor complete. Report saved to: ${OUTPUT_FILE}"

  local total critical high
  total=$(grep "Total:" "${OUTPUT_FILE}" | grep -v "Critical" | awk '{print $NF}')
  critical=$(grep "Critical" "${OUTPUT_FILE}" | grep -v "Severity" | awk '{print $NF}')
  high=$(grep "High" "${OUTPUT_FILE}" | grep -v "Severity" | awk '{print $NF}')
  send_slack_alert "${total}" "${critical}" "${high}"
  cat "${OUTPUT_FILE}"
}

main "$@"

#!/bin/bash

################################################################################
# AWS EFS Monitor
# Monitors EFS file systems for throughput, burst credits, connections, and storage
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/efs-monitor-$(date +%s).txt"
LOG_FILE="/var/log/efs-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
BURST_CREDIT_WARN="${BURST_CREDIT_WARN:-20}"           # percentage remaining
CONNECTION_WARN="${CONNECTION_WARN:-1000}"              # client connections
THROUGHPUT_PERCENT_WARN="${THROUGHPUT_PERCENT_WARN:-80}" # % of permitted throughput

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
start_window() { date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%SZ; }
now_window() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# API wrappers
list_file_systems() {
  aws efs describe-file-systems \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_mount_targets() {
  local fs_id="$1"
  aws efs describe-mount-targets \
    --file-system-id "${fs_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metric() {
  local fs_id="$1"; local metric="$2"; local stat="${3:-Average}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name "${metric}" \
    --dimensions Name=FileSystemId,Value="${fs_id}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].'${stat} \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{if(n>0) printf("%.2f", sum/n); else print "0"}'
}

write_header() {
  {
    echo "AWS EFS Monitoring Report"
    echo "========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "Burst Credit Warn: ${BURST_CREDIT_WARN}%"
    echo "Connection Warn: ${CONNECTION_WARN}"
    echo "Throughput Warn: ${THROUGHPUT_PERCENT_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_file_systems() {
  log_message INFO "Listing EFS file systems"
  {
    echo "=== FILE SYSTEMS ==="
  } >> "${OUTPUT_FILE}"

  local total=0 low_burst=0 high_connections=0 high_throughput=0

  local fs_json
  fs_json=$(list_file_systems)
  echo "${fs_json}" | jq -c '.FileSystems[]?' 2>/dev/null | while read -r fs; do
    ((total++))
    local fs_id name state size_bytes throughput_mode performance_mode encrypted kms_key lifecycle_policy num_mounts created
    fs_id=$(echo "${fs}" | jq_safe '.FileSystemId')
    name=$(echo "${fs}" | jq_safe '.Name')
    state=$(echo "${fs}" | jq_safe '.LifeCycleState')
    size_bytes=$(echo "${fs}" | jq_safe '.SizeInBytes.Value')
    throughput_mode=$(echo "${fs}" | jq_safe '.ThroughputMode')
    performance_mode=$(echo "${fs}" | jq_safe '.PerformanceMode')
    encrypted=$(echo "${fs}" | jq_safe '.Encrypted')
    kms_key=$(echo "${fs}" | jq_safe '.KmsKeyId')
    lifecycle_policy=$(echo "${fs}" | jq '.LifecyclePolicies | length' 2>/dev/null || echo 0)
    num_mounts=$(echo "${fs}" | jq_safe '.NumberOfMountTargets')
    created=$(echo "${fs}" | jq_safe '.CreationTime')

    # Convert bytes to GB
    local size_gb
    size_gb=$(awk "BEGIN {printf \"%.2f\", ${size_bytes}/1024/1024/1024}")

    # Get metrics
    local burst_credits client_conns data_read data_write throughput permitted_throughput
    burst_credits=$(get_metric "${fs_id}" "BurstCreditBalance" "Average" || echo "0")
    client_conns=$(get_metric "${fs_id}" "ClientConnections" "Average" || echo "0")
    data_read=$(get_metric "${fs_id}" "DataReadIOBytes" "Sum" || echo "0")
    data_write=$(get_metric "${fs_id}" "DataWriteIOBytes" "Sum" || echo "0")
    throughput=$(get_metric "${fs_id}" "MeteredIOBytes" "Average" || echo "0")
    permitted_throughput=$(get_metric "${fs_id}" "PermittedThroughput" "Average" || echo "0")

    # Convert throughput to MB/s
    local throughput_mb permitted_mb
    throughput_mb=$(awk "BEGIN {printf \"%.2f\", ${throughput}/1024/1024}")
    permitted_mb=$(awk "BEGIN {printf \"%.2f\", ${permitted_throughput}/1024/1024}")

    # Calculate throughput percentage
    local throughput_percent=0
    if (( $(echo "${permitted_mb} > 0" | bc -l) )); then
      throughput_percent=$(awk "BEGIN {printf \"%.0f\", (${throughput_mb}/${permitted_mb})*100}")
    fi

    {
      echo "File System: ${fs_id}"
      echo "  Name: ${name}"
      echo "  State: ${state}"
      echo "  Size: ${size_gb} GB"
      echo "  Throughput Mode: ${throughput_mode}"
      echo "  Performance Mode: ${performance_mode}"
      echo "  Encrypted: ${encrypted}"
    } >> "${OUTPUT_FILE}"

    if [[ -n "${kms_key}" && "${kms_key}" != "null" ]]; then
      echo "  KMS Key: ${kms_key}" >> "${OUTPUT_FILE}"
    fi

    {
      echo "  Mount Targets: ${num_mounts}"
      echo "  Lifecycle Policies: ${lifecycle_policy}"
      echo "  Created: ${created}"
      echo "  Burst Credit Balance: ${burst_credits}"
      echo "  Client Connections (avg): ${client_conns}"
      echo "  Throughput (avg): ${throughput_mb} MB/s"
      echo "  Permitted Throughput (avg): ${permitted_mb} MB/s"
      echo "  Throughput Utilization: ${throughput_percent}%"
    } >> "${OUTPUT_FILE}"

    # Flags
    if [[ "${throughput_mode}" == "bursting" ]]; then
      local burst_percent
      burst_percent=$(awk "BEGIN {printf \"%.0f\", (${burst_credits}/2199023255552)*100}" 2>/dev/null || echo 100)
      if (( burst_percent <= BURST_CREDIT_WARN )); then
        ((low_burst++))
        echo "  WARNING: Low burst credits (${burst_percent}% <= ${BURST_CREDIT_WARN}%)" >> "${OUTPUT_FILE}"
      fi
    fi

    if (( $(echo "${client_conns} >= ${CONNECTION_WARN}" | bc -l) )); then
      ((high_connections++))
      echo "  WARNING: High client connections (${client_conns} >= ${CONNECTION_WARN})" >> "${OUTPUT_FILE}"
    fi

    if (( throughput_percent >= THROUGHPUT_PERCENT_WARN )); then
      ((high_throughput++))
      echo "  WARNING: High throughput utilization (${throughput_percent}% >= ${THROUGHPUT_PERCENT_WARN}%)" >> "${OUTPUT_FILE}"
    fi

    if [[ "${state}" != "available" ]]; then
      echo "  WARNING: File system state is ${state}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "File System Summary:"
    echo "  Total: ${total}"
    echo "  Low Burst Credits: ${low_burst}"
    echo "  High Connections: ${high_connections}"
    echo "  High Throughput: ${high_throughput}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_mount_targets() {
  log_message INFO "Analyzing mount targets"
  {
    echo "=== MOUNT TARGETS ==="
  } >> "${OUTPUT_FILE}"

  local total_mounts=0

  local fs_json
  fs_json=$(list_file_systems)
  echo "${fs_json}" | jq -c '.FileSystems[]?' 2>/dev/null | while read -r fs; do
    local fs_id name
    fs_id=$(echo "${fs}" | jq_safe '.FileSystemId')
    name=$(echo "${fs}" | jq_safe '.Name')

    local mounts_json
    mounts_json=$(describe_mount_targets "${fs_id}")

    echo "${mounts_json}" | jq -c '.MountTargets[]?' 2>/dev/null | while read -r mt; do
      ((total_mounts++))
      local mt_id subnet_id az ip_address state
      mt_id=$(echo "${mt}" | jq_safe '.MountTargetId')
      subnet_id=$(echo "${mt}" | jq_safe '.SubnetId')
      az=$(echo "${mt}" | jq_safe '.AvailabilityZoneName')
      ip_address=$(echo "${mt}" | jq_safe '.IpAddress')
      state=$(echo "${mt}" | jq_safe '.LifeCycleState')

      {
        echo "File System: ${fs_id} (${name})"
        echo "  Mount Target: ${mt_id}"
        echo "  Subnet: ${subnet_id}"
        echo "  AZ: ${az}"
        echo "  IP: ${ip_address}"
        echo "  State: ${state}"
      } >> "${OUTPUT_FILE}"

      if [[ "${state}" != "available" ]]; then
        echo "  WARNING: Mount target state is ${state}" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Mount Target Summary:"
    echo "  Total: ${total_mounts}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_access_points() {
  log_message INFO "Checking access points"
  {
    echo "=== ACCESS POINTS ==="
  } >> "${OUTPUT_FILE}"

  local fs_json total_ap=0
  fs_json=$(list_file_systems)
  echo "${fs_json}" | jq -c '.FileSystems[]?' 2>/dev/null | while read -r fs; do
    local fs_id
    fs_id=$(echo "${fs}" | jq_safe '.FileSystemId')

    local ap_json
    ap_json=$(aws efs describe-access-points \
      --file-system-id "${fs_id}" \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{}')

    local ap_count
    ap_count=$(echo "${ap_json}" | jq '.AccessPoints | length' 2>/dev/null || echo 0)
    
    if (( ap_count > 0 )); then
      ((total_ap+=ap_count))
      {
        echo "File System: ${fs_id}"
        echo "  Access Points: ${ap_count}"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Access Point Summary:"
    echo "  Total: ${total_ap}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local low_burst="$2"; local high_conn="$3"; local high_through="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS EFS Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "File Systems", "value": "${total}", "short": true},
        {"title": "Low Burst Credits", "value": "${low_burst}", "short": true},
        {"title": "High Connections", "value": "${high_conn}", "short": true},
        {"title": "High Throughput", "value": "${high_through}", "short": true},
        {"title": "Burst Credit Warn", "value": "${BURST_CREDIT_WARN}%", "short": true},
        {"title": "Connection Warn", "value": "${CONNECTION_WARN}", "short": true},
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
  log_message INFO "Starting AWS EFS monitoring"
  write_header
  report_file_systems
  report_mount_targets
  report_access_points
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local total low_burst high_conn high_through
  total=$(list_file_systems | jq '.FileSystems | length' 2>/dev/null || echo 0)
  low_burst=$(grep -c "Low burst credits" "${OUTPUT_FILE}" || echo 0)
  high_conn=$(grep -c "High client connections" "${OUTPUT_FILE}" || echo 0)
  high_through=$(grep -c "High throughput utilization" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${total}" "${low_burst}" "${high_conn}" "${high_through}"
  cat "${OUTPUT_FILE}"
}

main "$@"

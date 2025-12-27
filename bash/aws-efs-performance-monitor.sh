#!/bin/bash

################################################################################
# AWS EFS Performance Monitor
# Audits EFS file systems: lists file systems, mount targets, throughput modes,
# encryption, lifecycle/IA, backup policy, and checks CloudWatch metrics
# (PercentIOLimit, BurstCreditBalance, DataReadIOBytes, DataWriteIOBytes,
# ClientConnections). Includes thresholds, logging, Slack/email alerts, and a
# text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/efs-performance-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/efs-performance-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
PERCENT_IO_WARN="${PERCENT_IO_WARN:-70}"               # % of IO limit (provisioned/elastic)
BURST_CREDIT_WARN_GIB="${BURST_CREDIT_WARN_GIB:-5}"    # GiB credits remaining (bursting)
CONNECTIONS_WARN="${CONNECTIONS_WARN:-500}"            # active client connections
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_FILESYSTEMS=0
FS_WITH_ISSUES=0
FS_LOW_CREDITS=0
FS_HIGH_IO=0
FS_HIGH_CONN=0
MOUNT_TARGET_ISSUES=0

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
      "title": "AWS EFS Alert",
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
    echo "AWS EFS Performance Monitor"
    echo "============================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Percent IO Warning: > ${PERCENT_IO_WARN}%"
    echo "  Burst Credit Warning: < ${BURST_CREDIT_WARN_GIB} GiB"
    echo "  Client Connections Warning: > ${CONNECTIONS_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_file_systems() {
  aws_cmd efs describe-file-systems \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"FileSystems":[]}'
}

list_mount_targets() {
  local fs_id="$1"
  aws_cmd efs describe-mount-targets \
    --file-system-id "$fs_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"MountTargets":[]}'
}

get_lifecycle_config() {
  local fs_id="$1"
  aws_cmd efs describe-lifecycle-configuration \
    --file-system-id "$fs_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"LifecyclePolicies":[]}'
}

get_backup_policy() {
  local fs_id="$1"
  aws_cmd efs describe-backup-policy \
    --file-system-id "$fs_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metric() {
  local fs_id="$1" metric="$2" stat_type="${3:-Average}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name "$metric" \
    --dimensions Name=FileSystemId,Value="$fs_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_max() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{m=($1>m)?$1:m} END {if(NR==0) print 0; else printf "%.2f", m}'; }

bytes_to_gib() {
  awk '{printf "%.2f", $1/1073741824}'
}

record_issue() {
  ISSUES+=("$1")
}

analyze_mount_targets() {
  local fs_id="$1"
  local mt_json
  mt_json=$(list_mount_targets "$fs_id")
  local mt_count
  mt_count=$(echo "${mt_json}" | jq -r '.MountTargets | length')
  local bad=0
  while read -r mt; do
    local mt_id state
    mt_id=$(echo "${mt}" | jq_safe '.MountTargetId')
    state=$(echo "${mt}" | jq_safe '.LifeCycleState')
    [[ "${state}" != "available" ]] && ((bad++))
  done <<< "$(echo "${mt_json}" | jq -c '.MountTargets[]?')"
  echo "  Mount Targets: ${mt_count} (unavailable: ${bad})" >> "${OUTPUT_FILE}"
  if (( bad > 0 )); then
    MOUNT_TARGET_ISSUES=$((MOUNT_TARGET_ISSUES + bad))
  fi
}

analyze_fs() {
  local fs_json="$1"
  local fs_id name size_gib encrypted throughput_mode prov_mibps perf_mode
  fs_id=$(echo "${fs_json}" | jq_safe '.FileSystemId')
  name=$(echo "${fs_json}" | jq -r '.Tags[]? | select(.Key=="Name") | .Value' 2>/dev/null | head -n1)
  [[ -z "${name}" || "${name}" == "null" ]] && name="(no-name)"
  size_gib=$(echo "${fs_json}" | jq_safe '.SizeInBytes.Value' | bytes_to_gib)
  encrypted=$(echo "${fs_json}" | jq_safe '.Encrypted')
  throughput_mode=$(echo "${fs_json}" | jq_safe '.ThroughputMode')
  prov_mibps=$(echo "${fs_json}" | jq_safe '.ProvisionedThroughputInMibps // 0')
  perf_mode=$(echo "${fs_json}" | jq_safe '.PerformanceMode')

  TOTAL_FILESYSTEMS=$((TOTAL_FILESYSTEMS + 1))
  log_message INFO "Analyzing EFS ${fs_id} (${name})"

  {
    echo "EFS: ${fs_id} (${name})"
    echo "  Size: ${size_gib} GiB"
    echo "  Encrypted: ${encrypted}"
    echo "  Performance Mode: ${perf_mode}"
    echo "  Throughput Mode: ${throughput_mode}${prov_mibps:+ (${prov_mibps} MiB/s provisioned)}"
  } >> "${OUTPUT_FILE}"

  # Lifecycle (IA/Archive)
  local lc_json
  lc_json=$(get_lifecycle_config "$fs_id")
  local lc_policies
  lc_policies=$(echo "${lc_json}" | jq -c '.LifecyclePolicies // []')
  echo "  Lifecycle Policies: ${lc_policies}" >> "${OUTPUT_FILE}"

  # Backup policy
  local backup_json backup_status
  backup_json=$(get_backup_policy "$fs_id")
  backup_status=$(echo "${backup_json}" | jq_safe '.BackupPolicy.Status // "DISABLED"')
  echo "  Backup Policy: ${backup_status}" >> "${OUTPUT_FILE}"

  # Mount targets
  analyze_mount_targets "$fs_id"

  # Metrics
  local percent_io burst_balance_bytes burst_gib read_bytes write_bytes conn_max
  percent_io=$(get_metric "$fs_id" "PercentIOLimit" "Maximum" | calculate_max)
  burst_balance_bytes=$(get_metric "$fs_id" "BurstCreditBalance" "Minimum" | calculate_avg)
  burst_gib=$(echo "${burst_balance_bytes}" | bytes_to_gib)
  read_bytes=$(get_metric "$fs_id" "DataReadIOBytes" "Sum" | calculate_sum)
  write_bytes=$(get_metric "$fs_id" "DataWriteIOBytes" "Sum" | calculate_sum)
  conn_max=$(get_metric "$fs_id" "ClientConnections" "Maximum" | calculate_max)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    Percent IO Limit (max): ${percent_io}%"
    echo "    Burst Credits (min est): ${burst_gib} GiB"
    echo "    Data Read (sum): ${read_bytes} bytes"
    echo "    Data Write (sum): ${write_bytes} bytes"
    echo "    Client Connections (max): ${conn_max}"
  } >> "${OUTPUT_FILE}"

  local fs_issue=0

  if [[ "${throughput_mode}" == "bursting" ]]; then
    if (( $(echo "${burst_gib} < ${BURST_CREDIT_WARN_GIB}" | bc -l 2>/dev/null || echo 0) )); then
      FS_LOW_CREDITS=$((FS_LOW_CREDITS + 1))
      fs_issue=1
      record_issue "EFS ${fs_id} (${name}) burst credits low (${burst_gib} GiB < ${BURST_CREDIT_WARN_GIB} GiB)"
    fi
  else
    if (( $(echo "${percent_io} > ${PERCENT_IO_WARN}" | bc -l 2>/dev/null || echo 0) )); then
      FS_HIGH_IO=$((FS_HIGH_IO + 1))
      fs_issue=1
      record_issue "EFS ${fs_id} (${name}) PercentIOLimit ${percent_io}% exceeds ${PERCENT_IO_WARN}%"
    fi
  fi

  if (( $(echo "${conn_max} > ${CONNECTIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    FS_HIGH_CONN=$((FS_HIGH_CONN + 1))
    fs_issue=1
    record_issue "EFS ${fs_id} (${name}) client connections ${conn_max} exceed ${CONNECTIONS_WARN}"
  fi

  if (( fs_issue )); then
    FS_WITH_ISSUES=$((FS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local fs_json
  fs_json=$(list_file_systems)
  local fs_count
  fs_count=$(echo "${fs_json}" | jq -r '.FileSystems | length')

  if [[ "${fs_count}" == "0" ]]; then
    log_message WARN "No EFS file systems found in region ${REGION}"
    echo "No EFS file systems found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total File Systems: ${fs_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r fs; do
    analyze_fs "${fs}"
  done <<< "$(echo "${fs_json}" | jq -c '.FileSystems[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total File Systems: ${TOTAL_FILESYSTEMS}"
    echo "File Systems with Issues: ${FS_WITH_ISSUES}"
    echo "Low Burst Credits: ${FS_LOW_CREDITS}"
    echo "High Percent IO: ${FS_HIGH_IO}"
    echo "High Connections: ${FS_HIGH_CONN}"
    echo "Mount Target Issues: ${MOUNT_TARGET_ISSUES}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "EFS Performance Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "EFS Performance Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

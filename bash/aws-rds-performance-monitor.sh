#!/bin/bash

################################################################################
# AWS RDS Performance Monitor
# Audits RDS instances/clusters: engine/edition/class/storage/encryption,
# multi-AZ, backups/snapshots, performance insights flag, read replicas, and
# CloudWatch metrics (CPUUtilization, FreeStorageSpace, FreeableMemory,
# ReadIOPS/WriteIOPS, ReadLatency/WriteLatency, DatabaseConnections,
# ReplicaLag). Includes thresholds, logging, Slack/email alerts, and a text
# report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/rds-performance-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/rds-performance-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
CPU_WARN_PCT="${CPU_WARN_PCT:-80}"
STORAGE_FREE_WARN_GB="${STORAGE_FREE_WARN_GB:-20}"
CONNECTIONS_WARN="${CONNECTIONS_WARN:-500}"
REPLICA_LAG_WARN_SEC="${REPLICA_LAG_WARN_SEC:-60}"
LATENCY_READ_WARN_MS="${LATENCY_READ_WARN_MS:-20}"
LATENCY_WRITE_WARN_MS="${LATENCY_WRITE_WARN_MS:-20}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_INSTANCES=0
INSTANCES_WITH_ISSUES=0
INSTANCES_HIGH_CPU=0
INSTANCES_LOW_STORAGE=0
INSTANCES_HIGH_CONN=0
INSTANCES_HIGH_LAG=0
INSTANCES_HIGH_LATENCY=0

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
      "title": "AWS RDS Alert",
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
    echo "AWS RDS Performance Monitor"
    echo "============================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  CPU Warning: > ${CPU_WARN_PCT}%"
    echo "  Free Storage Warning: < ${STORAGE_FREE_WARN_GB} GB"
    echo "  Connections Warning: > ${CONNECTIONS_WARN}"
    echo "  Replica Lag Warning: > ${REPLICA_LAG_WARN_SEC} sec"
    echo "  Read/Write Latency Warning: > ${LATENCY_READ_WARN_MS}/${LATENCY_WRITE_WARN_MS} ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_instances() {
  aws_cmd rds describe-db-instances \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"DBInstances":[]}'
}

get_metric() {
  local id="$1" metric="$2" stat_type="${3:-Average}" dim_name="${4:-DBInstanceIdentifier}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name "$metric" \
    --dimensions Name="${dim_name}",Value="$id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_max() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }
calculate_min() { jq -r '.Datapoints[].Minimum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1<m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }

bytes_to_gb() { awk '{printf "%.2f", $1/1073741824}' ; }

record_issue() {
  ISSUES+=("$1")
}

analyze_instance() {
  local inst_json="$1"
  local id engine engine_ver clazz storage_type allocated_gb multi_az encrypted endpoint port az
  id=$(echo "${inst_json}" | jq_safe '.DBInstanceIdentifier')
  engine=$(echo "${inst_json}" | jq_safe '.Engine')
  engine_ver=$(echo "${inst_json}" | jq_safe '.EngineVersion')
  clazz=$(echo "${inst_json}" | jq_safe '.DBInstanceClass')
  storage_type=$(echo "${inst_json}" | jq_safe '.StorageType')
  allocated_gb=$(echo "${inst_json}" | jq_safe '.AllocatedStorage')
  multi_az=$(echo "${inst_json}" | jq_safe '.MultiAZ')
  encrypted=$(echo "${inst_json}" | jq_safe '.StorageEncrypted')
  endpoint=$(echo "${inst_json}" | jq_safe '.Endpoint.Address')
  port=$(echo "${inst_json}" | jq_safe '.Endpoint.Port')
  az=$(echo "${inst_json}" | jq_safe '.AvailabilityZone')
  local pi_enabled
  pi_enabled=$(echo "${inst_json}" | jq_safe '.PerformanceInsightsEnabled')
  local replicas
  replicas=$(echo "${inst_json}" | jq -r '.ReadReplicaDBInstanceIdentifiers | length' 2>/dev/null || echo 0)

  TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))
  log_message INFO "Analyzing RDS ${id} (${engine})"

  {
    echo "RDS: ${id}"
    echo "  Engine: ${engine} ${engine_ver}"
    echo "  Class: ${clazz}"
    echo "  Storage: ${allocated_gb} GB (${storage_type})"
    echo "  Encrypted: ${encrypted}"
    echo "  Multi-AZ: ${multi_az}"
    echo "  Endpoint: ${endpoint}:${port}"
    echo "  AZ: ${az}"
    echo "  Performance Insights: ${pi_enabled}"
    echo "  Read Replicas: ${replicas}"
  } >> "${OUTPUT_FILE}"

  # Metrics
  local cpu free_storage free_mem conn read_iops write_iops read_lat write_lat lag
  cpu=$(get_metric "$id" "CPUUtilization" "Average" | calculate_avg)
  free_storage=$(get_metric "$id" "FreeStorageSpace" "Minimum" | calculate_min)
  free_mem=$(get_metric "$id" "FreeableMemory" "Minimum" | calculate_min)
  conn=$(get_metric "$id" "DatabaseConnections" "Maximum" | calculate_max)
  read_iops=$(get_metric "$id" "ReadIOPS" "Average" | calculate_avg)
  write_iops=$(get_metric "$id" "WriteIOPS" "Average" | calculate_avg)
  read_lat=$(get_metric "$id" "ReadLatency" "Average" | calculate_avg)
  write_lat=$(get_metric "$id" "WriteLatency" "Average" | calculate_avg)
  lag=$(get_metric "$id" "ReplicaLag" "Maximum" | calculate_max)

  local free_storage_gb
  free_storage_gb=$(echo "${free_storage}" | bytes_to_gb)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    CPU (avg): ${cpu}%"
    echo "    Free Storage (min): ${free_storage_gb} GB"
    echo "    Freeable Memory (min): ${free_mem} bytes"
    echo "    Connections (max): ${conn}"
    echo "    Read IOPS (avg): ${read_iops}"
    echo "    Write IOPS (avg): ${write_iops}"
    echo "    Read Latency (avg): ${read_lat} sec"
    echo "    Write Latency (avg): ${write_lat} sec"
    echo "    Replica Lag (max): ${lag} sec"
  } >> "${OUTPUT_FILE}"

  local inst_issue=0

  if (( $(echo "${cpu} > ${CPU_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    INSTANCES_HIGH_CPU=$((INSTANCES_HIGH_CPU + 1))
    inst_issue=1
    record_issue "RDS ${id} CPU ${cpu}% exceeds ${CPU_WARN_PCT}%"
  fi

  if (( $(echo "${free_storage_gb} < ${STORAGE_FREE_WARN_GB}" | bc -l 2>/dev/null || echo 0) )); then
    INSTANCES_LOW_STORAGE=$((INSTANCES_LOW_STORAGE + 1))
    inst_issue=1
    record_issue "RDS ${id} free storage ${free_storage_gb} GB below ${STORAGE_FREE_WARN_GB} GB"
  fi

  if (( $(echo "${conn} > ${CONNECTIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    INSTANCES_HIGH_CONN=$((INSTANCES_HIGH_CONN + 1))
    inst_issue=1
    record_issue "RDS ${id} connections ${conn} exceed ${CONNECTIONS_WARN}"
  fi

  if (( $(echo "${lag} > ${REPLICA_LAG_WARN_SEC}" | bc -l 2>/dev/null || echo 0) )); then
    INSTANCES_HIGH_LAG=$((INSTANCES_HIGH_LAG + 1))
    inst_issue=1
    record_issue "RDS ${id} replica lag ${lag}s exceeds ${REPLICA_LAG_WARN_SEC}s"
  fi

  if (( $(echo "${read_lat}*1000 > ${LATENCY_READ_WARN_MS}" | bc -l 2>/dev/null || echo 0) )) || (( $(echo "${write_lat}*1000 > ${LATENCY_WRITE_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    INSTANCES_HIGH_LATENCY=$((INSTANCES_HIGH_LATENCY + 1))
    inst_issue=1
    record_issue "RDS ${id} latency read/write ${read_lat}/${write_lat}s above ${LATENCY_READ_WARN_MS}/${LATENCY_WRITE_WARN_MS}ms"
  fi

  if (( inst_issue )); then
    INSTANCES_WITH_ISSUES=$((INSTANCES_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local inst_json
  inst_json=$(list_instances)
  local inst_count
  inst_count=$(echo "${inst_json}" | jq -r '.DBInstances | length')

  if [[ "${inst_count}" == "0" ]]; then
    log_message WARN "No RDS instances found in region ${REGION}"
    echo "No RDS instances found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total RDS Instances: ${inst_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r inst; do
    analyze_instance "${inst}"
  done <<< "$(echo "${inst_json}" | jq -c '.DBInstances[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Instances: ${TOTAL_INSTANCES}"
    echo "Instances with Issues: ${INSTANCES_WITH_ISSUES}"
    echo "High CPU: ${INSTANCES_HIGH_CPU}"
    echo "Low Storage: ${INSTANCES_LOW_STORAGE}"
    echo "High Connections: ${INSTANCES_HIGH_CONN}"
    echo "High Replica Lag: ${INSTANCES_HIGH_LAG}"
    echo "High Latency: ${INSTANCES_HIGH_LATENCY}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "RDS Performance Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "RDS Performance Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

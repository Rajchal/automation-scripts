#!/bin/bash

################################################################################
# AWS DocumentDB Cluster Monitor
# Audits DocumentDB clusters: instance status, class, storage, backup window,
# maintenance window, encryption, parameter groups; pulls CloudWatch metrics
# (CPUUtilization, FreeableMemory, DatabaseConnections, ReadIOPS/WriteIOPS,
# ReadLatency/WriteLatency, FreeLocalStorage, ReplicaLag) with thresholds.
# Includes logging, Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/docdb-cluster-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/docdb-cluster-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
CPU_WARN_PCT="${CPU_WARN_PCT:-80}"
CONNECTIONS_WARN="${CONNECTIONS_WARN:-500}"
LAG_WARN_SEC="${LAG_WARN_SEC:-60}"
LATENCY_READ_WARN_MS="${LATENCY_READ_WARN_MS:-15}"
LATENCY_WRITE_WARN_MS="${LATENCY_WRITE_WARN_MS:-15}"
STORAGE_FREE_WARN_GB="${STORAGE_FREE_WARN_GB:-20}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_CLUSTERS=0
CLUSTERS_WITH_ISSUES=0
CLUSTERS_HIGH_CPU=0
CLUSTERS_HIGH_CONN=0
CLUSTERS_HIGH_LAG=0
CLUSTERS_HIGH_LATENCY=0
CLUSTERS_LOW_STORAGE=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}



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
      "title": "AWS DocumentDB Alert",
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
    echo "AWS DocumentDB Cluster Monitor"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  CPU Warning: > ${CPU_WARN_PCT}%"
    echo "  Connections Warning: > ${CONNECTIONS_WARN}"
    echo "  Replica Lag Warning: > ${LAG_WARN_SEC}s"
    echo "  Read/Write Latency Warning: > ${LATENCY_READ_WARN_MS}/${LATENCY_WRITE_WARN_MS} ms"
    echo "  Free Storage Warning: < ${STORAGE_FREE_WARN_GB} GB"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws_cmd docdb describe-db-clusters \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"DBClusters":[]}'
}

list_instances() {
  aws_cmd docdb describe-db-instances \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"DBInstances":[]}'
}

get_metric() {
  local id="$1" metric="$2" stat_type="${3:-Average}" dim_name="${4:-DBClusterIdentifier}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/DocDB \
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

analyze_cluster() {
  local cluster_json="$1"
  local cid status engine engine_ver storage_encrypted backup_window maint_window
  cid=$(echo "${cluster_json}" | jq_safe '.DBClusterIdentifier')
  status=$(echo "${cluster_json}" | jq_safe '.Status')
  engine=$(echo "${cluster_json}" | jq_safe '.Engine')
  engine_ver=$(echo "${cluster_json}" | jq_safe '.EngineVersion')
  storage_encrypted=$(echo "${cluster_json}" | jq_safe '.StorageEncrypted')
  backup_window=$(echo "${cluster_json}" | jq_safe '.PreferredBackupWindow')
  maint_window=$(echo "${cluster_json}" | jq_safe '.PreferredMaintenanceWindow')

  TOTAL_CLUSTERS=$((TOTAL_CLUSTERS + 1))
  log_message INFO "Analyzing DocDB cluster ${cid}"

  {
    echo "Cluster: ${cid}"
    echo "  Status: ${status}"
    echo "  Engine: ${engine} ${engine_ver}"
    echo "  Storage Encrypted: ${storage_encrypted}"
    echo "  Backup Window: ${backup_window}"
    echo "  Maintenance Window: ${maint_window}"
  } >> "${OUTPUT_FILE}"

  # Metrics (cluster-level where applicable)
  local cpu conn lag read_lat write_lat free_local_storage_gb
  cpu=$(get_metric "$cid" "CPUUtilization" "Average" | calculate_avg)
  conn=$(get_metric "$cid" "DatabaseConnections" "Average" | calculate_avg)
  lag=$(get_metric "$cid" "ReplicaLag" "Maximum" | calculate_max)
  read_lat=$(get_metric "$cid" "ReadLatency" "Average" | calculate_avg)
  write_lat=$(get_metric "$cid" "WriteLatency" "Average" | calculate_avg)
  free_local_storage_gb=$(get_metric "$cid" "FreeLocalStorage" "Minimum" | calculate_min | bytes_to_gb)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    CPU (avg): ${cpu}%"
    echo "    Connections (avg): ${conn}"
    echo "    Replica Lag (max): ${lag} sec"
    echo "    Read Latency (avg): ${read_lat} sec"
    echo "    Write Latency (avg): ${write_lat} sec"
    echo "    Free Local Storage (min): ${free_local_storage_gb} GB"
  } >> "${OUTPUT_FILE}"

  local issue=0
  if (( $(echo "${cpu} > ${CPU_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_CPU=$((CLUSTERS_HIGH_CPU + 1))
    issue=1
    record_issue "DocDB ${cid} CPU ${cpu}% exceeds ${CPU_WARN_PCT}%"
  fi
  if (( $(echo "${conn} > ${CONNECTIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_CONN=$((CLUSTERS_HIGH_CONN + 1))
    issue=1
    record_issue "DocDB ${cid} connections ${conn} exceed ${CONNECTIONS_WARN}"
  fi
  if (( $(echo "${lag} > ${LAG_WARN_SEC}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_LAG=$((CLUSTERS_HIGH_LAG + 1))
    issue=1
    record_issue "DocDB ${cid} replica lag ${lag}s exceeds ${LAG_WARN_SEC}s"
  fi
  if (( $(echo "${read_lat}*1000 > ${LATENCY_READ_WARN_MS}" | bc -l 2>/dev/null || echo 0) )) || (( $(echo "${write_lat}*1000 > ${LATENCY_WRITE_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_LATENCY=$((CLUSTERS_HIGH_LATENCY + 1))
    issue=1
    record_issue "DocDB ${cid} latency read/write ${read_lat}/${write_lat}s above ${LATENCY_READ_WARN_MS}/${LATENCY_WRITE_WARN_MS}ms"
  fi
  if (( $(echo "${free_local_storage_gb} < ${STORAGE_FREE_WARN_GB}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_LOW_STORAGE=$((CLUSTERS_LOW_STORAGE + 1))
    issue=1
    record_issue "DocDB ${cid} free local storage ${free_local_storage_gb} GB below ${STORAGE_FREE_WARN_GB} GB"
  fi

  if (( issue )); then
    CLUSTERS_WITH_ISSUES=$((CLUSTERS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local clusters_json
  clusters_json=$(list_clusters)
  local cluster_count
  cluster_count=$(echo "${clusters_json}" | jq -r '.DBClusters | length')

  if [[ "${cluster_count}" == "0" ]]; then
    log_message WARN "No DocDB clusters found"
    echo "No DocumentDB clusters found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Clusters: ${cluster_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r cluster; do
    analyze_cluster "${cluster}"
  done <<< "$(echo "${clusters_json}" | jq -c '.DBClusters[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Clusters: ${TOTAL_CLUSTERS}"
    echo "Clusters with Issues: ${CLUSTERS_WITH_ISSUES}"
    echo "High CPU: ${CLUSTERS_HIGH_CPU}"
    echo "High Connections: ${CLUSTERS_HIGH_CONN}"
    echo "High Replica Lag: ${CLUSTERS_HIGH_LAG}"
    echo "High Latency: ${CLUSTERS_HIGH_LATENCY}"
    echo "Low Free Storage: ${CLUSTERS_LOW_STORAGE}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "DocumentDB Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "DocumentDB Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"
  done

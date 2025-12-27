#!/bin/bash

################################################################################
# AWS ElastiCache Performance Monitor
# Audits ElastiCache clusters (Redis & Memcached): engine/version, node type,
# cluster config, encryption, backup (Redis), maintenance window, multi-AZ,
# and CloudWatch metrics (CPUUtilization, BytesUsedForCache, EvictionRate,
# CacheHits/Misses, NetworkBytesIn/Out, ConnectionsActive, Replication lag
# for Redis). Includes thresholds, logging, Slack/email alerts, and a text
# report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/elasticache-performance-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/elasticache-performance-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
CPU_WARN_PCT="${CPU_WARN_PCT:-75}"
EVICTION_WARN="${EVICTION_WARN:-100}"                 # evictions count
HIT_RATE_WARN_PCT="${HIT_RATE_WARN_PCT:-80}"         # cache hit rate < this
CONNECTIONS_WARN="${CONNECTIONS_WARN:-1000}"
REPLICATION_LAG_WARN_SEC="${REPLICATION_LAG_WARN_SEC:-30}"
MEMORY_USAGE_WARN_PCT="${MEMORY_USAGE_WARN_PCT:-90}"
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
CLUSTERS_HIGH_EVICTION=0
CLUSTERS_LOW_HIT_RATE=0
CLUSTERS_NO_ENCRYPTION=0
CLUSTERS_NO_BACKUP=0
CLUSTERS_NO_MULTI_AZ=0

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
      "title": "AWS ElastiCache Alert",
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
    echo "AWS ElastiCache Performance Monitor"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  CPU Warning: > ${CPU_WARN_PCT}%"
    echo "  Eviction Warning: >= ${EVICTION_WARN} items"
    echo "  Hit Rate Warning: < ${HIT_RATE_WARN_PCT}%"
    echo "  Connections Warning: > ${CONNECTIONS_WARN}"
    echo "  Replication Lag Warning: > ${REPLICATION_LAG_WARN_SEC} sec"
    echo "  Memory Usage Warning: > ${MEMORY_USAGE_WARN_PCT}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws_cmd elasticache describe-cache-clusters \
    --show-cache-node-info \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"CacheClusters":[]}'
}

get_cluster_details() {
  local cluster_id="$1"
  aws_cmd elasticache describe-cache-clusters \
    --cache-cluster-id "$cluster_id" \
    --show-cache-node-info \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"CacheClusters":[]}'
}

get_metric() {
  local cluster_id="$1" metric="$2" stat_type="${3:-Average}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/ElastiCache \
    --metric-name "$metric" \
    --dimensions Name=CacheClusterId,Value="$cluster_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_max() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }
calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }

bytes_to_gb() { awk '{printf "%.2f", $1/1073741824}' ; }

record_issue() {
  ISSUES+=("$1")
}

analyze_cluster() {
  local cluster_json="$1"
  local cluster_id engine engine_ver node_type num_nodes multi_az encryption_at_transit encryption_at_rest auth_token
  cluster_id=$(echo "${cluster_json}" | jq_safe '.CacheClusterId')
  engine=$(echo "${cluster_json}" | jq_safe '.Engine')
  engine_ver=$(echo "${cluster_json}" | jq_safe '.EngineVersion')
  node_type=$(echo "${cluster_json}" | jq_safe '.CacheNodeType')
  num_nodes=$(echo "${cluster_json}" | jq -r '.CacheNodes | length')
  multi_az=$(echo "${cluster_json}" | jq_safe '.AutomaticFailover')
  encryption_at_transit=$(echo "${cluster_json}" | jq_safe '.TransitEncryptionEnabled')
  encryption_at_rest=$(echo "${cluster_json}" | jq_safe '.AtRestEncryptionEnabled')
  auth_token=$(echo "${cluster_json}" | jq_safe '.AuthTokenEnabled')

  local snapshot_retention=""
  if [[ "${engine}" == "redis" ]]; then
    snapshot_retention=$(echo "${cluster_json}" | jq_safe '.SnapshotRetentionLimit')
  fi

  TOTAL_CLUSTERS=$((TOTAL_CLUSTERS + 1))
  log_message INFO "Analyzing ElastiCache ${cluster_id} (${engine})"

  {
    echo "Cluster: ${cluster_id}"
    echo "  Engine: ${engine} ${engine_ver}"
    echo "  Node Type: ${node_type}"
    echo "  Nodes: ${num_nodes}"
    echo "  Multi-AZ: ${multi_az}"
    echo "  Encryption (Transit): ${encryption_at_transit}"
    echo "  Encryption (At Rest): ${encryption_at_rest}"
    echo "  Auth Token: ${auth_token}"
  } >> "${OUTPUT_FILE}"

  if [[ -n "${snapshot_retention}" && "${snapshot_retention}" != "null" ]]; then
    echo "  Snapshot Retention: ${snapshot_retention} days" >> "${OUTPUT_FILE}"
  fi

  # Metrics
  local cpu memory evictions hits misses hit_rate conn repl_lag net_in net_out
  cpu=$(get_metric "$cluster_id" "CPUUtilization" "Average" | calculate_avg)
  memory=$(get_metric "$cluster_id" "DatabaseMemoryUsagePercentage" "Average" | calculate_avg)
  evictions=$(get_metric "$cluster_id" "Evictions" "Sum" | calculate_sum)
  hits=$(get_metric "$cluster_id" "CacheHits" "Sum" | calculate_sum)
  misses=$(get_metric "$cluster_id" "CacheMisses" "Sum" | calculate_sum)
  conn=$(get_metric "$cluster_id" "CurrentConnections" "Maximum" | calculate_max)
  repl_lag=$(get_metric "$cluster_id" "ReplicationLag" "Maximum" | calculate_max)
  net_in=$(get_metric "$cluster_id" "NetworkBytesIn" "Sum" | calculate_sum)
  net_out=$(get_metric "$cluster_id" "NetworkBytesOut" "Sum" | calculate_sum)

  local hit_rate="0"
  local total_requests
  total_requests=$(awk -v h="${hits}" -v m="${misses}" 'BEGIN {printf "%.0f", h+m}')
  if (( $(echo "${total_requests} > 0" | bc -l 2>/dev/null || echo 0) )); then
    hit_rate=$(awk -v h="${hits}" -v t="${total_requests}" 'BEGIN {printf "%.2f", (h*100)/t}')
  fi

  local net_in_gb net_out_gb
  net_in_gb=$(echo "${net_in}" | bytes_to_gb)
  net_out_gb=$(echo "${net_out}" | bytes_to_gb)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    CPU (avg): ${cpu}%"
    echo "    Memory Usage (avg): ${memory}%"
    echo "    Evictions: ${evictions}"
    echo "    Cache Hits/Misses: ${hits}/${misses}"
    echo "    Hit Rate: ${hit_rate}%"
    echo "    Connections (max): ${conn}"
    echo "    Replication Lag (max): ${repl_lag} sec"
    echo "    Network In/Out: ${net_in_gb}/${net_out_gb} GB"
  } >> "${OUTPUT_FILE}"

  local cluster_issue=0

  if (( $(echo "${cpu} > ${CPU_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_CPU=$((CLUSTERS_HIGH_CPU + 1))
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} CPU ${cpu}% exceeds ${CPU_WARN_PCT}%"
  fi

  if (( $(echo "${evictions} >= ${EVICTION_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_EVICTION=$((CLUSTERS_HIGH_EVICTION + 1))
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} evictions ${evictions} >= ${EVICTION_WARN}"
  fi

  if (( $(echo "${hit_rate} < ${HIT_RATE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_LOW_HIT_RATE=$((CLUSTERS_LOW_HIT_RATE + 1))
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} hit rate ${hit_rate}% below ${HIT_RATE_WARN_PCT}%"
  fi

  if (( $(echo "${conn} > ${CONNECTIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} connections ${conn} exceed ${CONNECTIONS_WARN}"
  fi

  if [[ "${engine}" == "redis" ]] && (( $(echo "${repl_lag} > ${REPLICATION_LAG_WARN_SEC}" | bc -l 2>/dev/null || echo 0) )); then
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} replication lag ${repl_lag}s exceeds ${REPLICATION_LAG_WARN_SEC}s"
  fi

  if (( $(echo "${memory} > ${MEMORY_USAGE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    cluster_issue=1
    record_issue "ElastiCache ${cluster_id} memory usage ${memory}% exceeds ${MEMORY_USAGE_WARN_PCT}%"
  fi

  # Config checks
  if [[ "${encryption_at_transit}" != "true" ]]; then
    record_issue "ElastiCache ${cluster_id} transit encryption disabled"
  fi

  if [[ "${encryption_at_rest}" != "true" ]]; then
    record_issue "ElastiCache ${cluster_id} at-rest encryption disabled"
  fi

  if [[ "${engine}" == "redis" ]]; then
    if [[ -z "${snapshot_retention}" || "${snapshot_retention}" == "0" || "${snapshot_retention}" == "null" ]]; then
      CLUSTERS_NO_BACKUP=$((CLUSTERS_NO_BACKUP + 1))
      record_issue "ElastiCache ${cluster_id} backup disabled"
    fi
  fi

  if [[ "${multi_az}" != "enabled" ]]; then
    CLUSTERS_NO_MULTI_AZ=$((CLUSTERS_NO_MULTI_AZ + 1))
    record_issue "ElastiCache ${cluster_id} multi-AZ disabled"
  fi

  if (( cluster_issue )); then
    CLUSTERS_WITH_ISSUES=$((CLUSTERS_WITH_ISSUES + 1))
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local cluster_json
  cluster_json=$(list_clusters)
  local cluster_count
  cluster_count=$(echo "${cluster_json}" | jq -r '.CacheClusters | length')

  if [[ "${cluster_count}" == "0" ]]; then
    log_message WARN "No ElastiCache clusters found in region ${REGION}"
    echo "No ElastiCache clusters found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Clusters: ${cluster_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r cluster; do
    analyze_cluster "${cluster}"
  done <<< "$(echo "${cluster_json}" | jq -c '.CacheClusters[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Clusters: ${TOTAL_CLUSTERS}"
    echo "Clusters with Issues: ${CLUSTERS_WITH_ISSUES}"
    echo "High CPU: ${CLUSTERS_HIGH_CPU}"
    echo "High Evictions: ${CLUSTERS_HIGH_EVICTION}"
    echo "Low Hit Rate: ${CLUSTERS_LOW_HIT_RATE}"
    echo "No Encryption: ${CLUSTERS_NO_ENCRYPTION}"
    echo "No Backup (Redis): ${CLUSTERS_NO_BACKUP}"
    echo "No Multi-AZ: ${CLUSTERS_NO_MULTI_AZ}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "ElastiCache Performance Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "ElastiCache Performance Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

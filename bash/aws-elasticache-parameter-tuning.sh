#!/bin/bash

################################################################################
# AWS ElastiCache Parameter Tuning Optimizer
# Analyzes ElastiCache cluster metrics and recommends/applies parameter
# optimizations for memcached and Redis clusters based on actual usage patterns
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/elasticache-tuning-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/elasticache-tuning.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
DRY_RUN="${DRY_RUN:-true}"

# Metric thresholds for recommendations
CPU_USAGE_HIGH="${CPU_USAGE_HIGH:-75}"
EVICTION_RATE_HIGH="${EVICTION_RATE_HIGH:-1000}"                # evictions per minute
HIT_RATE_LOW="${HIT_RATE_LOW:-85}"                              # hit rate %
MEMORY_FRAGMENTATION_HIGH="${MEMORY_FRAGMENTATION_HIGH:-1.5}"  # ratio
CONNECTION_UTILIZATION_HIGH="${CONNECTION_UTILIZATION_HIGH:-80}" # %
REPLICATION_LAG_HIGH="${REPLICATION_LAG_HIGH:-5000}"            # milliseconds

# Analysis window
METRIC_PERIOD="${METRIC_PERIOD:-3600}"  # seconds
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

list_replication_groups() {
  aws elasticache describe-replication-groups \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ReplicationGroups":[]}'
}

describe_replication_group() {
  local group_id="$1"
  aws elasticache describe-replication-groups \
    --replication-group-id "${group_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ReplicationGroups":[]}'
}

list_cache_clusters() {
  aws elasticache describe-cache-clusters \
    --region "${REGION}" \
    --show-cache-node-info \
    --output json 2>/dev/null || echo '{"CacheClusters":[]}'
}

describe_cache_cluster() {
  local cluster_id="$1"
  aws elasticache describe-cache-clusters \
    --cache-cluster-id "${cluster_id}" \
    --region "${REGION}" \
    --show-cache-node-info \
    --output json 2>/dev/null || echo '{"CacheClusters":[]}'
}

describe_parameter_group() {
  local group_name="$1"
  aws elasticache describe-parameter-groups \
    --parameter-group-name "${group_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ParameterGroups":[]}'
}

describe_parameters() {
  local group_name="$1"
  aws elasticache describe-parameters \
    --parameter-group-name "${group_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Parameters":[]}'
}

get_cloudwatch_metrics() {
  local cache_cluster_id="$1"
  local metric_name="$2"
  local start_time
  local end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/ElastiCache" \
    --metric-name "${metric_name}" \
    --dimensions Name=CacheClusterId,Value="${cache_cluster_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Average,Maximum,Minimum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_metric_stats() {
  local metric_data="$1"
  local stat_type="${2:-Average}"  # Average, Maximum, Minimum
  
  echo "${metric_data}" | jq -r ".Datapoints[] | .${stat_type}" 2>/dev/null | \
    awk '{sum+=$1; count++} END {if (count > 0) printf "%.2f", sum/count; else print "0"}'
}

send_slack_alert() {
  local message="$1"
  local severity="$2"
  
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    return
  fi
  
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
      "title": "ElastiCache Tuning Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  curl -X POST -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK}" 2>/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then
    return
  fi
  
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS ElastiCache Parameter Tuning Report"
    echo "========================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Period: Last ${LOOKBACK_HOURS} hours"
    echo "Dry Run Mode: ${DRY_RUN}"
    echo ""
    echo "Tuning Thresholds:"
    echo "  CPU Usage High: ${CPU_USAGE_HIGH}%"
    echo "  Eviction Rate High: ${EVICTION_RATE_HIGH}/min"
    echo "  Hit Rate Low: ${HIT_RATE_LOW}%"
    echo "  Memory Fragmentation: ${MEMORY_FRAGMENTATION_HIGH}"
    echo "  Connection Utilization: ${CONNECTION_UTILIZATION_HIGH}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

analyze_cache_clusters() {
  log_message INFO "Starting ElastiCache cluster analysis"
  
  {
    echo "=== CLUSTER ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local total_clusters=0
  local optimization_opportunities=0
  
  local clusters_json
  clusters_json=$(list_cache_clusters)
  
  local cluster_ids
  cluster_ids=$(echo "${clusters_json}" | jq -r '.CacheClusters[].CacheClusterId' 2>/dev/null)
  
  if [[ -z "${cluster_ids}" ]]; then
    log_message WARN "No ElastiCache clusters found in region ${REGION}"
    {
      echo "Status: No clusters found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r cluster_id; do
    ((total_clusters++))
    
    log_message INFO "Analyzing cluster: ${cluster_id}"
    
    local cluster_details
    cluster_details=$(describe_cache_cluster "${cluster_id}")
    
    local engine
    local engine_version
    local node_type
    local num_cache_nodes
    local cache_node_type
    local parameter_group
    local status
    
    engine=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].Engine')
    engine_version=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].EngineVersion')
    node_type=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].CacheNodeType')
    num_cache_nodes=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].NumCacheNodes')
    status=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].CacheClusterStatus')
    parameter_group=$(echo "${cluster_details}" | jq_safe '.CacheClusters[0].CacheParameterGroup.ParameterGroupName')
    
    {
      echo "Cluster ID: ${cluster_id}"
      echo "Engine: ${engine} ${engine_version}"
      echo "Node Type: ${node_type}"
      echo "Num Nodes: ${num_cache_nodes}"
      echo "Status: ${status}"
      echo "Parameter Group: ${parameter_group}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ "${status}" != "available" ]]; then
      {
        echo "⚠️  Cluster not available for analysis (Status: ${status})"
        echo ""
      } >> "${OUTPUT_FILE}"
      continue
    fi
    
    # Get metrics
    local cpu_metrics
    local eviction_metrics
    local hit_rate_metrics
    local memory_metrics
    local connection_metrics
    
    cpu_metrics=$(get_cloudwatch_metrics "${cluster_id}" "CPUUtilization")
    eviction_metrics=$(get_cloudwatch_metrics "${cluster_id}" "Evictions")
    hit_rate_metrics=$(get_cloudwatch_metrics "${cluster_id}" "CacheHitRate")
    memory_metrics=$(get_cloudwatch_metrics "${cluster_id}" "DatabaseMemoryUsageCountedForEvictPercentage")
    connection_metrics=$(get_cloudwatch_metrics "${cluster_id}" "CurrConnections")
    
    local cpu_avg
    local eviction_rate
    local hit_rate
    local memory_usage
    
    cpu_avg=$(calculate_metric_stats "${cpu_metrics}" "Average")
    eviction_rate=$(calculate_metric_stats "${eviction_metrics}" "Average")
    hit_rate=$(calculate_metric_stats "${hit_rate_metrics}" "Average")
    memory_usage=$(calculate_metric_stats "${memory_metrics}" "Average")
    
    {
      echo "Current Metrics:"
      echo "  CPU Utilization: ${cpu_avg}%"
      echo "  Eviction Rate: ${eviction_rate}/min"
      echo "  Cache Hit Rate: ${hit_rate}%"
      echo "  Memory Usage: ${memory_usage}%"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze and recommend parameters
    local recommendations=0
    {
      echo "Tuning Recommendations:"
    } >> "${OUTPUT_FILE}"
    
    # High CPU usage
    if (( $(echo "${cpu_avg} > ${CPU_USAGE_HIGH}" | bc -l) )); then
      {
        echo "  🔴 High CPU Utilization (${cpu_avg}%)"
        if [[ "${engine}" == "redis" ]]; then
          echo "    → Increase maxmemory-policy to 'allkeys-lru' or 'allkeys-lfu'"
          echo "    → Enable slow log to identify expensive operations"
          echo "    → Consider upgrading node type for more CPU capacity"
        fi
        echo ""
      } >> "${OUTPUT_FILE}"
      ((recommendations++))
      ((optimization_opportunities++))
      log_message WARN "Cluster ${cluster_id} has high CPU usage: ${cpu_avg}%"
    fi
    
    # High eviction rate
    if (( $(echo "${eviction_rate} > ${EVICTION_RATE_HIGH}" | bc -l) )); then
      {
        echo "  🟡 High Eviction Rate (${eviction_rate}/min)"
        echo "    → Increase maxmemory setting"
        echo "    → Review item expiration policies"
        echo "    → Consider upgrading to larger node type"
        echo ""
      } >> "${OUTPUT_FILE}"
      ((recommendations++))
      ((optimization_opportunities++))
      log_message WARN "Cluster ${cluster_id} has high eviction rate"
    fi
    
    # Low hit rate
    if (( $(echo "${hit_rate} < ${HIT_RATE_LOW}" | bc -l) )); then
      {
        echo "  🟠 Low Cache Hit Rate (${hit_rate}%)"
        echo "    → Analyze query patterns and cache usage"
        echo "    → Increase cache size to accommodate more data"
        echo "    → Review TTL settings for frequently accessed items"
        echo ""
      } >> "${OUTPUT_FILE}"
      ((recommendations++))
      ((optimization_opportunities++))
      log_message WARN "Cluster ${cluster_id} has low cache hit rate"
    fi
    
    # High memory usage
    if (( $(echo "${memory_usage} > 90" | bc -l) )); then
      {
        echo "  🔴 High Memory Pressure (${memory_usage}%)"
        echo "    → Increase allocated memory capacity"
        echo "    → Tune eviction policy to be more aggressive"
        echo "    → Review and optimize stored data size"
        echo ""
      } >> "${OUTPUT_FILE}"
      ((recommendations++))
      ((optimization_opportunities++))
      log_message WARN "Cluster ${cluster_id} has high memory pressure"
    fi
    
    if [[ ${recommendations} -eq 0 ]]; then
      {
        echo "  ✓ Cluster is well-tuned"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
    
    # Show current parameter group settings
    if [[ -n "${parameter_group}" && "${parameter_group}" != "null" ]]; then
      log_message INFO "Retrieving parameters for group: ${parameter_group}"
      
      {
        echo ""
        echo "Current Parameter Group: ${parameter_group}"
        echo "Key Parameters:"
      } >> "${OUTPUT_FILE}"
      
      local params_json
      params_json=$(describe_parameters "${parameter_group}")
      
      # Show key parameters
      echo "${params_json}" | jq -r '.Parameters[] | select(.ParameterName | test("maxmemory|maxmemory-policy|tcp-backlog|timeout|databases")) | "\(.ParameterName)=\(.ParameterValue)"' 2>/dev/null | while read -r param; do
        {
          echo "  ${param}"
        } >> "${OUTPUT_FILE}"
      done
    fi
    
    {
      echo ""
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${cluster_ids}"
  
  # Summary
  {
    echo ""
    echo "=== OPTIMIZATION SUMMARY ==="
    echo "Total Clusters: ${total_clusters}"
    echo "Optimization Opportunities: ${optimization_opportunities}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  log_message INFO "Analysis complete. Total: ${total_clusters}, Opportunities: ${optimization_opportunities}"
}

analyze_replication_groups() {
  log_message INFO "Analyzing replication groups"
  
  {
    echo ""
    echo "=== REPLICATION GROUP ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local groups_json
  groups_json=$(list_replication_groups)
  
  local group_ids
  group_ids=$(echo "${groups_json}" | jq -r '.ReplicationGroups[].ReplicationGroupId' 2>/dev/null)
  
  if [[ -z "${group_ids}" ]]; then
    {
      echo "No replication groups found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r group_id; do
    log_message INFO "Analyzing replication group: ${group_id}"
    
    local group_details
    group_details=$(describe_replication_group "${group_id}")
    
    local status
    local engine
    local node_type
    local num_cache_clusters
    
    status=$(echo "${group_details}" | jq_safe '.ReplicationGroups[0].Status')
    engine=$(echo "${group_details}" | jq_safe '.ReplicationGroups[0].Engine')
    node_type=$(echo "${group_details}" | jq_safe '.ReplicationGroups[0].CacheNodeType')
    num_cache_clusters=$(echo "${group_details}" | jq_safe '.ReplicationGroups[0].MemberClusters | length')
    
    {
      echo "Replication Group: ${group_id}"
      echo "Engine: ${engine}"
      echo "Node Type: ${node_type}"
      echo "Status: ${status}"
      echo "Member Clusters: ${num_cache_clusters}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${group_ids}"
}

performance_tuning_guide() {
  {
    echo ""
    echo "=== PERFORMANCE TUNING BEST PRACTICES ==="
    echo ""
    echo "Redis Specific:"
    echo "  • maxmemory-policy: Set appropriate eviction strategy"
    echo "    - allkeys-lru: Evict any key based on LRU (good for cache)"
    echo "    - volatile-lru: Evict keys with TTL based on LRU"
    echo "    - allkeys-lfu: Evict based on least frequently used"
    echo "  • timeout: Connection idle timeout (0 = never)"
    echo "  • tcp-backlog: TCP listen backlog"
    echo ""
    echo "Memcached Specific:"
    echo "  • max_item_size: Maximum size of items (bytes)"
    echo "  • chunk_size: Size of chunks for memory allocation"
    echo "  • growth_factor: Memory allocation growth multiplier"
    echo ""
    echo "General Recommendations:"
    echo "  • Monitor CPU, memory, and eviction metrics"
    echo "  • Use slow log (Redis) to identify expensive commands"
    echo "  • Implement proper key expiration (TTL) strategies"
    echo "  • Use connection pooling on application side"
    echo "  • Monitor replication lag for multi-AZ deployments"
    echo "  • Enable encryption for sensitive data"
    echo "  • Use parameter groups for consistent configuration"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== ElastiCache Parameter Tuning Optimizer Started ==="
  
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_message INFO "Running in DRY-RUN mode - no changes will be applied"
    {
      echo ""
      echo "⚠️  DRY-RUN MODE - Recommendations only, no changes applied"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
  
  write_header
  analyze_cache_clusters
  analyze_replication_groups
  performance_tuning_guide
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== ElastiCache Parameter Tuning Optimizer Completed ==="
}

main "$@"

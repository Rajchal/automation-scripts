#!/bin/bash

################################################################################
# AWS Aurora Cluster Monitor
# Monitors Aurora-specific features: global databases, replica lag, backtrack, cloning
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/aurora-monitor-$(date +%s).txt"
LOG_FILE="/var/log/aurora-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
REPLICA_LAG_WARN_MS="${REPLICA_LAG_WARN_MS:-1000}"     # milliseconds
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"                   # percentage
BUFFER_CACHE_HIT_WARN="${BUFFER_CACHE_HIT_WARN:-90}"   # percentage (warn if below)

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
list_aurora_clusters() {
  aws rds describe-db-clusters \
    --region "${REGION}" \
    --query 'DBClusters[?Engine==`aurora-mysql` || Engine==`aurora-postgresql` || Engine==`aurora`]' \
    --output json 2>/dev/null || echo '[]'
}

describe_global_clusters() {
  aws rds describe-global-clusters \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_cluster_metric() {
  local cluster_id="$1"; local metric="$2"; local stat="${3:-Average}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name "${metric}" \
    --dimensions Name=DBClusterIdentifier,Value="${cluster_id}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].'${stat} \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{if(n>0) printf("%.2f", sum/n); else print "0"}'
}

get_instance_metric() {
  local instance_id="$1"; local metric="$2"; local stat="${3:-Average}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
    --metric-name "${metric}" \
    --dimensions Name=DBInstanceIdentifier,Value="${instance_id}" \
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
    echo "AWS Aurora Cluster Monitoring Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "Replica Lag Warn: ${REPLICA_LAG_WARN_MS}ms"
    echo "CPU Threshold: ${CPU_THRESHOLD}%"
    echo "Buffer Cache Hit Warn: ${BUFFER_CACHE_HIT_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_aurora_clusters() {
  log_message INFO "Listing Aurora clusters"
  {
    echo "=== AURORA CLUSTERS ==="
  } >> "${OUTPUT_FILE}"

  local total=0 unhealthy=0 backtrack_enabled=0 serverless_count=0

  local clusters_json
  clusters_json=$(list_aurora_clusters)
  echo "${clusters_json}" | jq -c '.[]' 2>/dev/null | while read -r cluster; do
    ((total++))
    local cluster_id engine engine_version status multi_az members endpoints backtrack_window capacity clone_group serverless_version
    cluster_id=$(echo "${cluster}" | jq_safe '.DBClusterIdentifier')
    engine=$(echo "${cluster}" | jq_safe '.Engine')
    engine_version=$(echo "${cluster}" | jq_safe '.EngineVersion')
    status=$(echo "${cluster}" | jq_safe '.Status')
    multi_az=$(echo "${cluster}" | jq_safe '.MultiAZ')
    members=$(echo "${cluster}" | jq '.DBClusterMembers | length' 2>/dev/null || echo 0)
    endpoints=$(echo "${cluster}" | jq '.Endpoint' 2>/dev/null || echo "")
    backtrack_window=$(echo "${cluster}" | jq_safe '.BacktrackWindow')
    capacity=$(echo "${cluster}" | jq_safe '.Capacity')
    clone_group=$(echo "${cluster}" | jq_safe '.CloneGroupId')
    serverless_version=$(echo "${cluster}" | jq_safe '.ServerlessV2ScalingConfiguration.MinCapacity')

    {
      echo "Cluster: ${cluster_id}"
      echo "  Engine: ${engine} ${engine_version}"
      echo "  Status: ${status}"
      echo "  Multi-AZ: ${multi_az}"
      echo "  Members: ${members}"
    } >> "${OUTPUT_FILE}"

    # Backtrack
    if [[ -n "${backtrack_window}" && "${backtrack_window}" != "null" && "${backtrack_window}" != "0" ]]; then
      ((backtrack_enabled++))
      echo "  Backtrack: ENABLED (${backtrack_window} hours)" >> "${OUTPUT_FILE}"
    else
      echo "  Backtrack: DISABLED" >> "${OUTPUT_FILE}"
    fi

    # Serverless
    if [[ -n "${serverless_version}" && "${serverless_version}" != "null" ]]; then
      ((serverless_count++))
      local max_capacity
      max_capacity=$(echo "${cluster}" | jq_safe '.ServerlessV2ScalingConfiguration.MaxCapacity')
      echo "  Serverless v2: Min=${serverless_version} ACU, Max=${max_capacity} ACU" >> "${OUTPUT_FILE}"
    elif [[ -n "${capacity}" && "${capacity}" != "null" ]]; then
      echo "  Serverless v1: Capacity=${capacity} ACU" >> "${OUTPUT_FILE}"
    fi

    # Clone info
    if [[ -n "${clone_group}" && "${clone_group}" != "null" ]]; then
      echo "  Clone Group: ${clone_group}" >> "${OUTPUT_FILE}"
    fi

    # Status check
    if [[ "${status}" != "available" ]]; then
      ((unhealthy++))
      echo "  WARNING: Cluster status is ${status}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Cluster Summary:"
    echo "  Total Aurora Clusters: ${total}"
    echo "  Unhealthy: ${unhealthy}"
    echo "  Backtrack Enabled: ${backtrack_enabled}"
    echo "  Serverless: ${serverless_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_replica_lag() {
  log_message INFO "Analyzing Aurora replica lag"
  {
    echo "=== REPLICA LAG ANALYSIS ==="
  } >> "${OUTPUT_FILE}"

  local high_lag_count=0

  local clusters_json
  clusters_json=$(list_aurora_clusters)
  echo "${clusters_json}" | jq -c '.[]' 2>/dev/null | while read -r cluster; do
    local cluster_id members
    cluster_id=$(echo "${cluster}" | jq_safe '.DBClusterIdentifier')
    members=$(echo "${cluster}" | jq -c '.DBClusterMembers[]' 2>/dev/null)

    echo "${members}" | while read -r member; do
      local instance_id is_writer promotion_tier
      instance_id=$(echo "${member}" | jq_safe '.DBInstanceIdentifier')
      is_writer=$(echo "${member}" | jq_safe '.IsClusterWriter')
      promotion_tier=$(echo "${member}" | jq_safe '.PromotionTier')

      # Skip writer
      [[ "${is_writer}" == "true" ]] && continue

      # Get replica lag
      local lag_ms
      lag_ms=$(get_instance_metric "${instance_id}" "AuroraReplicaLag" "Average")

      {
        echo "Cluster: ${cluster_id}"
        echo "  Replica: ${instance_id}"
        echo "    Promotion Tier: ${promotion_tier}"
        echo "    Replica Lag: ${lag_ms}ms"
      } >> "${OUTPUT_FILE}"

      if (( $(echo "${lag_ms} >= ${REPLICA_LAG_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
        ((high_lag_count++))
        echo "    WARNING: High replica lag (${lag_ms}ms >= ${REPLICA_LAG_WARN_MS}ms)" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Replica Lag Summary:"
    echo "  High Lag Replicas: ${high_lag_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_global_databases() {
  log_message INFO "Checking Aurora Global Databases"
  {
    echo "=== GLOBAL DATABASES ==="
  } >> "${OUTPUT_FILE}"

  local global_json total_global=0
  global_json=$(describe_global_clusters)
  total_global=$(echo "${global_json}" | jq '.GlobalClusters | length' 2>/dev/null || echo 0)

  echo "${global_json}" | jq -c '.GlobalClusters[]?' 2>/dev/null | while read -r gdb; do
    local global_id engine status members
    global_id=$(echo "${gdb}" | jq_safe '.GlobalClusterIdentifier')
    engine=$(echo "${gdb}" | jq_safe '.Engine')
    status=$(echo "${gdb}" | jq_safe '.Status')
    members=$(echo "${gdb}" | jq '.GlobalClusterMembers | length' 2>/dev/null || echo 0)

    {
      echo "Global Database: ${global_id}"
      echo "  Engine: ${engine}"
      echo "  Status: ${status}"
      echo "  Member Clusters: ${members}"
    } >> "${OUTPUT_FILE}"

    # List members
    echo "${gdb}" | jq -c '.GlobalClusterMembers[]?' 2>/dev/null | while read -r member; do
      local cluster_arn is_writer region
      cluster_arn=$(echo "${member}" | jq_safe '.DBClusterArn')
      is_writer=$(echo "${member}" | jq_safe '.IsWriter')
      region=$(echo "${cluster_arn}" | cut -d: -f4)

      {
        echo "    Region: ${region}"
        echo "    Role: $([ "${is_writer}" = "true" ] && echo "PRIMARY" || echo "SECONDARY")"
        echo "    ARN: ${cluster_arn}"
      } >> "${OUTPUT_FILE}"
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Global Database Summary:"
    echo "  Total: ${total_global}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_performance_insights() {
  log_message INFO "Checking Performance Insights status"
  {
    echo "=== PERFORMANCE INSIGHTS ==="
  } >> "${OUTPUT_FILE}"

  local pi_enabled=0 pi_disabled=0

  local clusters_json
  clusters_json=$(list_aurora_clusters)
  echo "${clusters_json}" | jq -c '.[]' 2>/dev/null | while read -r cluster; do
    local cluster_id members
    cluster_id=$(echo "${cluster}" | jq_safe '.DBClusterIdentifier')
    members=$(echo "${cluster}" | jq -c '.DBClusterMembers[]' 2>/dev/null)

    echo "${members}" | while read -r member; do
      local instance_id
      instance_id=$(echo "${member}" | jq_safe '.DBInstanceIdentifier')

      local instance_details
      instance_details=$(aws rds describe-db-instances \
        --db-instance-identifier "${instance_id}" \
        --region "${REGION}" \
        --query 'DBInstances[0]' \
        --output json 2>/dev/null || echo '{}')

      local pi_status retention
      pi_status=$(echo "${instance_details}" | jq_safe '.PerformanceInsightsEnabled')
      retention=$(echo "${instance_details}" | jq_safe '.PerformanceInsightsRetentionPeriod')

      {
        echo "Instance: ${instance_id} (Cluster: ${cluster_id})"
      } >> "${OUTPUT_FILE}"

      if [[ "${pi_status}" == "true" ]]; then
        ((pi_enabled++))
        echo "  Performance Insights: ENABLED (Retention: ${retention} days)" >> "${OUTPUT_FILE}"
      else
        ((pi_disabled++))
        echo "  Performance Insights: DISABLED" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Performance Insights Summary:"
    echo "  Enabled: ${pi_enabled}"
    echo "  Disabled: ${pi_disabled}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_cache_efficiency() {
  log_message INFO "Analyzing buffer cache hit ratio"
  {
    echo "=== CACHE EFFICIENCY ==="
  } >> "${OUTPUT_FILE}"

  local low_hit_rate=0

  local clusters_json
  clusters_json=$(list_aurora_clusters)
  echo "${clusters_json}" | jq -c '.[]' 2>/dev/null | while read -r cluster; do
    local cluster_id members
    cluster_id=$(echo "${cluster}" | jq_safe '.DBClusterIdentifier')
    members=$(echo "${cluster}" | jq -c '.DBClusterMembers[]' 2>/dev/null)

    echo "${members}" | while read -r member; do
      local instance_id
      instance_id=$(echo "${member}" | jq_safe '.DBInstanceIdentifier')

      local cache_hit_ratio
      cache_hit_ratio=$(get_instance_metric "${instance_id}" "BufferCacheHitRatio" "Average")

      {
        echo "Instance: ${instance_id} (Cluster: ${cluster_id})"
        echo "  Buffer Cache Hit Ratio: ${cache_hit_ratio}%"
      } >> "${OUTPUT_FILE}"

      if (( $(echo "${cache_hit_ratio} < ${BUFFER_CACHE_HIT_WARN}" | bc -l 2>/dev/null || echo 0) )); then
        ((low_hit_rate++))
        echo "  WARNING: Low cache hit ratio (${cache_hit_ratio}% < ${BUFFER_CACHE_HIT_WARN}%)" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Cache Efficiency Summary:"
    echo "  Low Hit Rate Instances: ${low_hit_rate}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local unhealthy="$2"; local high_lag="$3"; local global_db="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Aurora Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Clusters", "value": "${total}", "short": true},
        {"title": "Unhealthy", "value": "${unhealthy}", "short": true},
        {"title": "High Replica Lag", "value": "${high_lag}", "short": true},
        {"title": "Global Databases", "value": "${global_db}", "short": true},
        {"title": "Replica Lag Warn", "value": "${REPLICA_LAG_WARN_MS}ms", "short": true},
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
  log_message INFO "Starting AWS Aurora monitoring"
  write_header
  report_aurora_clusters
  report_replica_lag
  report_global_databases
  report_performance_insights
  report_cache_efficiency
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local total unhealthy high_lag global_db
  total=$(list_aurora_clusters | jq 'length' 2>/dev/null || echo 0)
  unhealthy=$(grep -c "WARNING: Cluster status" "${OUTPUT_FILE}" || echo 0)
  high_lag=$(grep -c "High replica lag" "${OUTPUT_FILE}" || echo 0)
  global_db=$(describe_global_clusters | jq '.GlobalClusters | length' 2>/dev/null || echo 0)
  send_slack_alert "${total}" "${unhealthy}" "${high_lag}" "${global_db}"
  cat "${OUTPUT_FILE}"
}

main "$@"

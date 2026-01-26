#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-elasticache-cluster-monitor.log"
REPORT_FILE="/tmp/elasticache-cluster-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
CPU_THRESH="${ELASTICACHE_CPU_WARN:-80}"
FREEABLE_MEM_MB_THRESH="${ELASTICACHE_FREEABLE_MEM_MB_WARN:-100}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LOOKBACK_MINUTES="${ELASTICACHE_LOOKBACK_MINUTES:-5}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "ElastiCache Cluster Monitor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "CPU warn: ${CPU_THRESH}%" >> "$REPORT_FILE"
  echo "FreeableMem warn: ${FREEABLE_MEM_MB_THRESH} MB" >> "$REPORT_FILE"
  echo "Lookback minutes: ${LOOKBACK_MINUTES}" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

get_metric_max() {
  # args: metric namespace name dimensionName dimensionValue period start end
  aws cloudwatch get-metric-statistics --namespace "$1" --metric-name "$2" --dimensions Name=$3,Value="$4" --start-time "$5" --end-time "$6" --period $7 --statistics Maximum --region "$REGION" --output json 2>/dev/null | jq -r '[.Datapoints[].Maximum] | max // 0'
}

main() {
  write_header

  rg_json=$(aws elasticache describe-replication-groups --region "$REGION" --output json 2>/dev/null || echo '{"ReplicationGroups":[]}')
  rg_count=$(echo "$rg_json" | jq '.ReplicationGroups | length')

  total=0
  alerts=0

  if [ "$rg_count" -gt 0 ]; then
    echo "Replication Groups:" >> "$REPORT_FILE"
    echo "$rg_json" | jq -c '.ReplicationGroups[]' | while read -r rg; do
      name=$(echo "$rg" | jq -r '.ReplicationGroupId')
      status=$(echo "$rg" | jq -r '.Status')
      node_groups=$(echo "$rg" | jq -r '.MemberClusters | join(",")')
      echo "Group: $name" >> "$REPORT_FILE"
      echo "Status: $status" >> "$REPORT_FILE"
      echo "Members: $node_groups" >> "$REPORT_FILE"
      echo "" >> "$REPORT_FILE"

      for member in $(echo "$rg" | jq -r '.MemberClusters[]'); do
        total=$((total+1))
        cluster_json=$(aws elasticache describe-cache-clusters --cache-cluster-id "$member" --show-cache-node-info --region "$REGION" --output json 2>/dev/null || echo '{}')
        cluster_status=$(echo "$cluster_json" | jq -r '.CacheClusters[0].CacheClusterStatus // "<unknown>"')
        node_ids=$(echo "$cluster_json" | jq -r '.CacheClusters[0].CacheNodes[].CacheNodeId' | paste -sd, -)

        echo "Cluster: $member" >> "$REPORT_FILE"
        echo "Status: $cluster_status" >> "$REPORT_FILE"
        echo "NodeIds: $node_ids" >> "$REPORT_FILE"

        # metrics per cluster (CPUUtilization and FreeableMemory)
        end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        start_time=$(date -u -d "${LOOKBACK_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
        cpu_max=$(get_metric_max "AWS/ElastiCache" "CPUUtilization" "CacheClusterId" "$member"  "$start_time" "$end_time" 60)
        mem_max=$(get_metric_max "AWS/ElastiCache" "FreeableMemory" "CacheClusterId" "$member"  "$start_time" "$end_time" 60)

        # FreeableMemory returned in bytes for some engines; normalize to MB if large
        if [ "$mem_max" -gt 1048576 ]; then
          mem_mb=$((mem_max / 1024 / 1024))
        else
          mem_mb=$mem_max
        fi

        echo "CPU max: $cpu_max" >> "$REPORT_FILE"
        echo "FreeableMemory max (MB): $mem_mb" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"

        if [ "$(printf '%s' "$cpu_max" | awk '{print ($1+0)}')" -ge "$CPU_THRESH" ] || [ "$mem_mb" -lt "$FREEABLE_MEM_MB_THRESH" ]; then
          send_slack_alert "ElastiCache Alert: Cluster $member in $REGION status=$cluster_status CPU_max=${cpu_max}% FreeableMem_MB=${mem_mb}"
          alerts=$((alerts+1))
        fi
      done
    done
  fi

  # Also check standalone cache clusters (not in replication groups)
  cc_json=$(aws elasticache describe-cache-clusters --show-cache-node-info --region "$REGION" --output json 2>/dev/null || echo '{"CacheClusters":[]}')
  echo "Standalone Cache Clusters:" >> "$REPORT_FILE"
  echo "$cc_json" | jq -c '.CacheClusters[]' | while read -r cc; do
    cid=$(echo "$cc" | jq -r '.CacheClusterId')
    total=$((total+1))
    status=$(echo "$cc" | jq -r '.CacheClusterStatus // "<unknown>"')
    node_ids=$(echo "$cc" | jq -r '.CacheNodes[].CacheNodeId' | paste -sd, -)

    echo "Cluster: $cid" >> "$REPORT_FILE"
    echo "Status: $status" >> "$REPORT_FILE"
    echo "NodeIds: $node_ids" >> "$REPORT_FILE"

    end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    start_time=$(date -u -d "${LOOKBACK_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
    cpu_max=$(get_metric_max "AWS/ElastiCache" "CPUUtilization" "CacheClusterId" "$cid"  "$start_time" "$end_time" 60)
    mem_max=$(get_metric_max "AWS/ElastiCache" "FreeableMemory" "CacheClusterId" "$cid"  "$start_time" "$end_time" 60)

    if [ "$mem_max" -gt 1048576 ]; then
      mem_mb=$((mem_max / 1024 / 1024))
    else
      mem_mb=$mem_max
    fi

    echo "CPU max: $cpu_max" >> "$REPORT_FILE"
    echo "FreeableMemory max (MB): $mem_mb" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$(printf '%s' "$cpu_max" | awk '{print ($1+0)}')" -ge "$CPU_THRESH" ] || [ "$mem_mb" -lt "$FREEABLE_MEM_MB_THRESH" ]; then
      send_slack_alert "ElastiCache Alert: Cluster $cid in $REGION status=$status CPU_max=${cpu_max}% FreeableMem_MB=${mem_mb}"
      alerts=$((alerts+1))
    fi
  done

  echo "Summary: total_clusters=$total, alerts=$alerts" >> "$REPORT_FILE"
  log_message "ElastiCache report written to $REPORT_FILE (total_clusters=$total, alerts=$alerts)"
}

main "$@"

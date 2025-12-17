#!/bin/bash

################################################################################
# AWS DocumentDB Monitor
# Monitors DocumentDB clusters and instances for availability and performance
# Detects cluster health, replication lag, and backup status
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/documentdb-monitor-$(date +%s).txt"
LOG_FILE="/var/log/documentdb-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"                 # % utilization
MEMORY_THRESHOLD="${MEMORY_THRESHOLD:-80}"           # % utilization
REPLICATION_LAG_WARN="${REPLICATION_LAG_WARN:-5000}" # milliseconds
BACKUP_RETENTION_MIN="${BACKUP_RETENTION_MIN:-7}"    # days

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
list_db_clusters() {
  aws docdb describe-db-clusters \
    --region "${REGION}" \
    --query 'DBClusters[*].[DBClusterIdentifier,Engine,Status,MemberCount]' \
    --output text 2>/dev/null || true
}

describe_db_cluster() {
  local cluster_id="$1"
  aws docdb describe-db-clusters \
    --db-cluster-identifier "${cluster_id}" \
    --region "${REGION}" \
    --query 'DBClusters[0]' \
    --output json 2>/dev/null || echo '{}'
}

list_db_instances() {
  aws docdb describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass,DBInstanceStatus,DBClusterIdentifier]' \
    --output text 2>/dev/null || true
}

describe_db_instance() {
  local instance_id="$1"
  aws docdb describe-db-instances \
    --db-instance-identifier "${instance_id}" \
    --region "${REGION}" \
    --query 'DBInstances[0]' \
    --output json 2>/dev/null || echo '{}'
}

get_cluster_events() {
  aws docdb describe-events \
    --source-type "db-cluster" \
    --duration 1440 \
    --region "${REGION}" \
    --query 'Events[*]' \
    --output json 2>/dev/null | head -100 || echo '[]'
}

get_metric() {
  local db_id="$1"; local metric="$2"; local stat="${3:-Average}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/DocDB \
    --metric-name "${metric}" \
    --dimensions Name=DBInstanceIdentifier,Value="${db_id}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].'${stat} \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{if(n>0) printf("%.0f", sum/n); else print "0"}'
}

write_header() {
  {
    echo "AWS DocumentDB Cluster Monitoring Report"
    echo "========================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "CPU Threshold: ${CPU_THRESHOLD}%"
    echo "Memory Threshold: ${MEMORY_THRESHOLD}%"
    echo "Replication Lag Warning: ${REPLICATION_LAG_WARN}ms"
    echo "Min Backup Retention: ${BACKUP_RETENTION_MIN} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_db_clusters() {
  log_message INFO "Listing DocumentDB clusters"
  {
    echo "=== DB CLUSTERS ==="
  } >> "${OUTPUT_FILE}"

  local total_clusters=0 unhealthy_clusters=0 high_lag_count=0

  list_db_clusters | while IFS=$'\t' read -r cluster_id engine status member_count; do
    [[ -z "${cluster_id}" ]] && continue
    ((total_clusters++))

    local config backup_retention storage_encrypted iam_auth enabled_logs
    config=$(describe_db_cluster "${cluster_id}")
    backup_retention=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    storage_encrypted=$(echo "${config}" | jq_safe '.StorageEncrypted')
    iam_auth=$(echo "${config}" | jq_safe '.IAMDatabaseAuthenticationEnabled')
    enabled_logs=$(echo "${config}" | jq '.EnabledCloudwatchLogsExports | length' 2>/dev/null || echo "0")

    {
      echo "Cluster: ${cluster_id}"
      echo "  Engine: ${engine}"
      echo "  Status: ${status}"
      echo "  Members: ${member_count}"
      echo "  Encrypted: ${storage_encrypted}"
      echo "  IAM Auth: ${iam_auth}"
      echo "  Backup Retention: ${backup_retention} days"
      echo "  CloudWatch Logs: ${enabled_logs} types"
    } >> "${OUTPUT_FILE}"

    # Check backup retention
    if [[ -n "${backup_retention}" && "${backup_retention}" != "null" ]]; then
      if (( backup_retention < BACKUP_RETENTION_MIN )); then
        echo "  WARNING: Backup retention below minimum (${backup_retention}d < ${BACKUP_RETENTION_MIN}d)" >> "${OUTPUT_FILE}"
      fi
    fi

    # Check cluster status
    if [[ "${status}" != "available" ]]; then
      ((unhealthy_clusters++))
      echo "  WARNING: Cluster status is ${status}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Cluster Summary:"
    echo "  Total Clusters: ${total_clusters}"
    echo "  Unhealthy: ${unhealthy_clusters}"
    echo "  High Replication Lag: ${high_lag_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_db_instances() {
  log_message INFO "Listing DocumentDB instances"
  {
    echo "=== DB INSTANCES ==="
  } >> "${OUTPUT_FILE}"

  local high_cpu_count=0 high_memory_count=0 failed_count=0

  list_db_instances | while IFS=$'\t' read -r instance_id class status cluster_id; do
    [[ -z "${instance_id}" ]] && continue

    local config availability_zone promotion_tier
    config=$(describe_db_instance "${instance_id}")
    availability_zone=$(echo "${config}" | jq_safe '.AvailabilityZone')
    promotion_tier=$(echo "${config}" | jq_safe '.PromotionTier')

    # Get metrics
    local cpu memory
    cpu=$(get_metric "${instance_id}" "CPUUtilization" "Average" || echo "0")
    memory=$(get_metric "${instance_id}" "MemoryUtilization" "Average" || echo "0")

    {
      echo "Instance: ${instance_id}"
      echo "  Cluster: ${cluster_id}"
      echo "  Class: ${class}"
      echo "  Status: ${status}"
      echo "  Availability Zone: ${availability_zone}"
      echo "  Promotion Tier: ${promotion_tier}"
      echo "  CPU (avg): ${cpu}%"
      echo "  Memory (avg): ${memory}%"
    } >> "${OUTPUT_FILE}"

    # Flags
    if (( cpu >= CPU_THRESHOLD )); then
      ((high_cpu_count++))
      echo "  WARNING: High CPU utilization (${cpu}% >= ${CPU_THRESHOLD}%)" >> "${OUTPUT_FILE}"
    fi
    if (( memory >= MEMORY_THRESHOLD )); then
      ((high_memory_count++))
      echo "  WARNING: High memory utilization (${memory}% >= ${MEMORY_THRESHOLD}%)" >> "${OUTPUT_FILE}"
    fi

    # Check if unhealthy
    if [[ "${status}" != "available" ]]; then
      ((failed_count++))
      echo "  WARNING: Instance status is ${status}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Instance Summary:"
    echo "  High CPU: ${high_cpu_count}"
    echo "  High Memory: ${high_memory_count}"
    echo "  Unhealthy Status: ${failed_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_replication() {
  log_message INFO "Analyzing cluster replication"
  {
    echo "=== REPLICATION ANALYSIS ==="
  } >> "${OUTPUT_FILE}"

  list_db_clusters | while IFS=$'\t' read -r cluster_id _ _ _; do
    [[ -z "${cluster_id}" ]] && continue

    local config members
    config=$(describe_db_cluster "${cluster_id}")
    members=$(echo "${config}" | jq '.DBClusterMembers' 2>/dev/null || echo '[]')

    {
      echo "Cluster: ${cluster_id}"
    } >> "${OUTPUT_FILE}"

    echo "${members}" | jq -c '.[]' 2>/dev/null | while read -r member; do
      local member_id promotion_tier is_writer
      member_id=$(echo "${member}" | jq_safe '.DBInstanceIdentifier')
      promotion_tier=$(echo "${member}" | jq_safe '.PromotionTier')
      is_writer=$(echo "${member}" | jq_safe '.IsClusterWriter')

      {
        echo "  Member: ${member_id}"
        echo "    Role: $([ "${is_writer}" = "true" ] && echo "PRIMARY" || echo "REPLICA")"
        echo "    Promotion Tier: ${promotion_tier}"
      } >> "${OUTPUT_FILE}"
    done

    echo "" >> "${OUTPUT_FILE}"
  done
}

report_cluster_events() {
  log_message INFO "Collecting recent cluster events"
  {
    echo "=== RECENT CLUSTER EVENTS (last 24h) ==="
  } >> "${OUTPUT_FILE}"

  local events_json
  events_json=$(get_cluster_events)
  echo "${events_json}" | jq -c '.[]' 2>/dev/null | head -20 | while read -r e; do
    local date msg src
    date=$(echo "${e}" | jq_safe '.Date')
    msg=$(echo "${e}" | jq_safe '.Message')
    src=$(echo "${e}" | jq_safe '.SourceIdentifier')

    {
      echo "${date}  ${src}"
      echo "  ${msg}"
    } >> "${OUTPUT_FILE}"
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_backup_recovery() {
  log_message INFO "Checking backup and recovery readiness"
  {
    echo "=== BACKUP & RECOVERY READINESS ==="
  } >> "${OUTPUT_FILE}"

  list_db_clusters | while IFS=$'\t' read -r cluster_id _ _ _; do
    [[ -z "${cluster_id}" ]] && continue

    local config backup_retention earliest_restore latest_restore encrypted
    config=$(describe_db_cluster "${cluster_id}")
    backup_retention=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    earliest_restore=$(echo "${config}" | jq_safe '.EarliestRestorableTime')
    latest_restore=$(echo "${config}" | jq_safe '.LatestRestorableTime')
    encrypted=$(echo "${config}" | jq_safe '.StorageEncrypted')

    {
      echo "Cluster: ${cluster_id}"
      echo "  Backup Retention: ${backup_retention} days"
      echo "  Encrypted: ${encrypted}"
      echo "  Earliest Restorable: ${earliest_restore}"
      echo "  Latest Restorable: ${latest_restore}"
    } >> "${OUTPUT_FILE}"

    # Check if backup retention is zero (disabled)
    if [[ "${backup_retention}" == "0" ]]; then
      echo "  WARNING: Automated backups disabled" >> "${OUTPUT_FILE}"
    fi

    # Check encryption
    if [[ "${encrypted}" != "true" ]]; then
      echo "  WARNING: Cluster storage not encrypted" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

monitor_parameter_groups() {
  log_message INFO "Checking parameter group configurations"
  {
    echo "=== PARAMETER GROUPS ==="
  } >> "${OUTPUT_FILE}"

  local param_groups
  param_groups=$(aws docdb describe-db-cluster-parameter-groups \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}')

  local pg_count
  pg_count=$(echo "${param_groups}" | jq '.DBClusterParameterGroups | length' 2>/dev/null || echo 0)

  {
    echo "Total Parameter Groups: ${pg_count}"
    echo ""
  } >> "${OUTPUT_FILE}"

  echo "${param_groups}" | jq -c '.DBClusterParameterGroups[]' 2>/dev/null | while read -r pg; do
    local pg_name pg_family
    pg_name=$(echo "${pg}" | jq_safe '.DBClusterParameterGroupName')
    pg_family=$(echo "${pg}" | jq_safe '.DBParameterGroupFamily')

    {
      echo "Parameter Group: ${pg_name}"
      echo "  Family: ${pg_family}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local cluster_count="$1"; local unhealthy="$2"; local high_cpu="$3"; local high_mem="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS DocumentDB Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Clusters", "value": "${cluster_count}", "short": true},
        {"title": "Unhealthy", "value": "${unhealthy}", "short": true},
        {"title": "High CPU", "value": "${high_cpu}", "short": true},
        {"title": "High Memory", "value": "${high_mem}", "short": true},
        {"title": "CPU Threshold", "value": "${CPU_THRESHOLD}%", "short": true},
        {"title": "Memory Threshold", "value": "${MEMORY_THRESHOLD}%", "short": true},
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
  log_message INFO "Starting AWS DocumentDB monitoring"
  write_header
  report_db_clusters
  report_db_instances
  monitor_replication
  report_cluster_events
  monitor_backup_recovery
  monitor_parameter_groups
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local cluster_count unhealthy_count high_cpu high_mem
  cluster_count=$(aws docdb describe-db-clusters --region "${REGION}" --query 'length(DBClusters)' --output text 2>/dev/null || echo 0)
  unhealthy_count=$(grep -c "WARNING: Cluster status" "${OUTPUT_FILE}" || echo 0)
  high_cpu=$(grep -c "High CPU" "${OUTPUT_FILE}" || echo 0)
  high_mem=$(grep -c "High memory" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${cluster_count}" "${unhealthy_count}" "${high_cpu}" "${high_mem}"
  cat "${OUTPUT_FILE}"
}

main "$@"

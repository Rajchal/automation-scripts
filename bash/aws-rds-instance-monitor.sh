#!/bin/bash

################################################################################
# AWS RDS Instance Monitor
# Monitors RDS instances and clusters for availability, performance, and failover
# Detects CPU spikes, connection limits, storage pressure, and failed backups
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/rds-monitor-$(date +%s).txt"
LOG_FILE="/var/log/rds-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"               # % utilization
STORAGE_THRESHOLD="${STORAGE_THRESHOLD:-80}"       # % used
DB_CONN_WARN_PERCENT="${DB_CONN_WARN_PERCENT:-80}"  # % of max connections
FAILED_BACKUP_THRESHOLD="${FAILED_BACKUP_THRESHOLD:-1}"

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
list_db_instances() {
  aws rds describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[*].[DBInstanceIdentifier,DBInstanceClass,Engine,DBInstanceStatus,MultiAZ,StorageType]' \
    --output text 2>/dev/null || true
}

describe_db_instance() {
  local db_id="$1"
  aws rds describe-db-instances \
    --db-instance-identifier "${db_id}" \
    --region "${REGION}" \
    --query 'DBInstances[0]' \
    --output json 2>/dev/null || echo '{}'
}

list_db_clusters() {
  aws rds describe-db-clusters \
    --region "${REGION}" \
    --query 'DBClusters[*].[DBClusterIdentifier,Engine,Status,MultiAZ,Members]' \
    --output text 2>/dev/null || true
}

list_db_events() {
  aws rds describe-events \
    --duration 1440 \
    --region "${REGION}" \
    --query 'Events[*]' \
    --output json 2>/dev/null | head -100 || echo '[]'
}

get_metric() {
  local db_id="$1"; local metric="$2"; local stat="${3:-Average}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RDS \
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
    echo "AWS RDS Instance Monitoring Report"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "CPU Threshold: ${CPU_THRESHOLD}%"
    echo "Storage Threshold: ${STORAGE_THRESHOLD}%"
    echo "Connection Warning: ${DB_CONN_WARN_PERCENT}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_db_instances() {
  log_message INFO "Listing RDS instances"
  {
    echo "=== DB INSTANCES ==="
  } >> "${OUTPUT_FILE}"

  local high_cpu_count=0 high_storage_count=0 failed_count=0

  list_db_instances | while IFS=$'\t' read -r db_id class engine status multi_az storage_type; do
    [[ -z "${db_id}" ]] && continue

    local config
    config=$(describe_db_instance "${db_id}")

    local endpoint backup_retention auto_backup encrypted read_replicas storage_alloc
    endpoint=$(echo "${config}" | jq_safe '.Endpoint.Address')
    backup_retention=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    auto_backup=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    encrypted=$(echo "${config}" | jq_safe '.StorageEncrypted')
    read_replicas=$(echo "${config}" | jq '.ReadReplicaDBInstanceIdentifiers | length' 2>/dev/null || echo "0")
    storage_alloc=$(echo "${config}" | jq_safe '.AllocatedStorage')

    # Get metrics
    local cpu connections db_load free_space
    cpu=$(get_metric "${db_id}" "CPUUtilization" "Average" || echo "0")
    connections=$(get_metric "${db_id}" "DatabaseConnections" "Average" || echo "0")
    db_load=$(get_metric "${db_id}" "DBLoad" "Average" || echo "0")
    free_space=$(get_metric "${db_id}" "FreeStorageSpace" "Average" || echo "0")

    # Calculate storage utilization
    local storage_util=0
    if [[ -n "${storage_alloc}" && "${storage_alloc}" != "null" ]]; then
      local alloc_bytes=$(( storage_alloc * 1024 * 1024 * 1024 ))
      if (( alloc_bytes > 0 )); then
        storage_util=$(( (alloc_bytes - free_space) * 100 / alloc_bytes ))
      fi
    fi

    {
      echo "Instance: ${db_id}"
      echo "  Status: ${status}"
      echo "  Class: ${class}  Engine: ${engine}"
      echo "  Multi-AZ: ${multi_az}  Storage Type: ${storage_type}"
      echo "  Endpoint: ${endpoint}"
      echo "  Storage: ${storage_alloc}GB (${storage_util}% used)"
      echo "  Encrypted: ${encrypted}"
      echo "  Backup Retention: ${backup_retention} days"
      echo "  Read Replicas: ${read_replicas}"
      echo "  CPU (avg): ${cpu}%"
      echo "  Connections: ${connections}"
      echo "  DB Load: ${db_load}"
      echo "  Free Storage: ${free_space} bytes"
    } >> "${OUTPUT_FILE}"

    # Flags
    if (( cpu >= CPU_THRESHOLD )); then
      ((high_cpu_count++))
      echo "  WARNING: High CPU utilization (${cpu}% >= ${CPU_THRESHOLD}%)" >> "${OUTPUT_FILE}"
    fi
    if (( storage_util >= STORAGE_THRESHOLD )); then
      ((high_storage_count++))
      echo "  WARNING: High storage utilization (${storage_util}% >= ${STORAGE_THRESHOLD}%)" >> "${OUTPUT_FILE}"
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
    echo "  High Storage: ${high_storage_count}"
    echo "  Unhealthy Status: ${failed_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_db_clusters() {
  log_message INFO "Listing RDS clusters"
  {
    echo "=== DB CLUSTERS ==="
  } >> "${OUTPUT_FILE}"

  list_db_clusters | while IFS=$'\t' read -r cluster_id engine status multi_az members; do
    [[ -z "${cluster_id}" ]] && continue

    local member_count
    member_count=$(echo "${members}" | jq 'length' 2>/dev/null || echo "0")

    {
      echo "Cluster: ${cluster_id}"
      echo "  Engine: ${engine}"
      echo "  Status: ${status}"
      echo "  Multi-AZ: ${multi_az}"
      echo "  Members: ${member_count}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

monitor_backups() {
  log_message INFO "Checking automated backups"
  {
    echo "=== BACKUP MONITORING ==="
  } >> "${OUTPUT_FILE}"

  local latest_backup_time failed_backups=0

  list_db_instances | while IFS=$'\t' read -r db_id _ _ _ _ _; do
    [[ -z "${db_id}" ]] && continue

    local config backup_window backup_retention auto_backup latest_restore
    config=$(describe_db_instance "${db_id}")
    backup_window=$(echo "${config}" | jq_safe '.PreferredBackupWindow')
    backup_retention=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    auto_backup=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    latest_restore=$(echo "${config}" | jq_safe '.LatestRestorableTime')

    {
      echo "Instance: ${db_id}"
      echo "  Backup Window: ${backup_window}"
      echo "  Retention: ${backup_retention} days"
      echo "  Latest Restorable: ${latest_restore}"
    } >> "${OUTPUT_FILE}"

    # Check if backup retention is zero (disabled)
    if [[ "${backup_retention}" == "0" ]]; then
      ((failed_backups++))
      echo "  WARNING: Automated backups disabled" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  if (( failed_backups >= FAILED_BACKUP_THRESHOLD )); then
    log_message WARN "Found ${failed_backups} instances with disabled backups"
  fi
}

report_recent_events() {
  log_message INFO "Collecting recent RDS events"
  {
    echo "=== RECENT EVENTS (last 24h) ==="
  } >> "${OUTPUT_FILE}"

  local events_json
  events_json=$(list_db_events)
  echo "${events_json}" | jq -c '.[]' | head -20 | while read -r e; do
    local date msg src type
    date=$(echo "${e}" | jq_safe '.Date')
    msg=$(echo "${e}" | jq_safe '.Message')
    src=$(echo "${e}" | jq_safe '.SourceIdentifier')
    type=$(echo "${e}" | jq_safe '.SourceType')

    {
      echo "${date}  [${type}] ${src}"
      echo "  ${msg}"
    } >> "${OUTPUT_FILE}"
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_failover_readiness() {
  log_message INFO "Analyzing failover readiness"
  {
    echo "=== FAILOVER READINESS ==="
  } >> "${OUTPUT_FILE}"

  list_db_instances | while IFS=$'\t' read -r db_id _ engine status multi_az _; do
    [[ -z "${db_id}" ]] && continue

    local config backup_retention enhanced_monitoring
    config=$(describe_db_instance "${db_id}")
    backup_retention=$(echo "${config}" | jq_safe '.BackupRetentionPeriod')
    enhanced_monitoring=$(echo "${config}" | jq_safe '.EnabledCloudwatchLogsExports | length')

    {
      echo "Instance: ${db_id}"
      echo "  Multi-AZ: ${multi_az}"
      echo "  Backup Retention: ${backup_retention} days"
      echo "  CloudWatch Logs Enabled: ${enhanced_monitoring} types"
    } >> "${OUTPUT_FILE}"

    if [[ "${multi_az}" != "true" ]]; then
      echo "  WARNING: Multi-AZ not enabled" >> "${OUTPUT_FILE}"
    fi
    if [[ "${backup_retention}" == "0" || "${backup_retention}" == "1" ]]; then
      echo "  WARNING: Low backup retention (${backup_retention} day)" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local instance_count="$1"; local high_cpu="$2"; local high_storage="$3"; local unhealthy="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS RDS Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Instances", "value": "${instance_count}", "short": true},
        {"title": "High CPU", "value": "${high_cpu}", "short": true},
        {"title": "High Storage", "value": "${high_storage}", "short": true},
        {"title": "Unhealthy", "value": "${unhealthy}", "short": true},
        {"title": "CPU Threshold", "value": "${CPU_THRESHOLD}%", "short": true},
        {"title": "Storage Threshold", "value": "${STORAGE_THRESHOLD}%", "short": true},
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
  log_message INFO "Starting AWS RDS monitoring"
  write_header
  report_db_instances
  report_db_clusters
  monitor_backups
  report_recent_events
  monitor_failover_readiness
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local instance_count high_cpu high_storage unhealthy
  instance_count=$(aws rds describe-db-instances --region "${REGION}" --query 'length(DBInstances)' --output text 2>/dev/null || echo 0)
  high_cpu=$(grep -c "High CPU" "${OUTPUT_FILE}" || echo 0)
  high_storage=$(grep -c "High storage" "${OUTPUT_FILE}" || echo 0)
  unhealthy=$(grep -c "WARNING: Instance status" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${instance_count}" "${high_cpu}" "${high_storage}" "${unhealthy}"
  cat "${OUTPUT_FILE}"
}

main "$@"

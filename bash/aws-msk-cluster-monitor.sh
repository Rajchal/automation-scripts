#!/bin/bash

################################################################################
# AWS MSK Cluster Monitor
# Monitors MSK clusters and brokers for health, storage, throughput, and ISR
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/msk-monitor-$(date +%s).txt"
LOG_FILE="/var/log/msk-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
CPU_THRESHOLD="${CPU_THRESHOLD:-80}"                 # % utilization
STORAGE_USED_THRESHOLD="${STORAGE_USED_THRESHOLD:-80}" # % used
UNDER_REPL_FACTOR_WARN="${UNDER_REPL_FACTOR_WARN:-1}"   # under-replicated partitions
MSK_NAMESPACE="AWS/Kafka"

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
list_clusters() {
  aws kafka list-clusters-v2 \
    --region "${REGION}" \
    --query 'ClusterInfoList[*].ClusterArn' \
    --output text 2>/dev/null || true
}

describe_cluster() {
  local arn="$1"
  aws kafka describe-cluster-v2 \
    --cluster-arn "${arn}" \
    --region "${REGION}" \
    --query 'ClusterInfo' \
    --output json 2>/dev/null || echo '{}'
}

list_cluster_nodes() {
  local arn="$1"
  aws kafka list-nodes \
    --cluster-arn "${arn}" \
    --region "${REGION}" \
    --query 'NodeInfoList' \
    --output json 2>/dev/null || echo '[]'
}

get_metric() {
  local cluster_name="$1"; local metric="$2"; local stat="${3:-Average}"; local dim_name="${4:-ClusterName}"; local dim_value="${5:-$cluster_name}"
  local period=300
  aws cloudwatch get-metric-statistics \
    --namespace "${MSK_NAMESPACE}" \
    --metric-name "${metric}" \
    --dimensions Name=${dim_name},Value="${dim_value}" \
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
    echo "AWS MSK Cluster Monitoring Report"
    echo "================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo "CPU Threshold: ${CPU_THRESHOLD}%"
    echo "Storage Used Threshold: ${STORAGE_USED_THRESHOLD}%"
    echo "Under-Replicated Warn: ${UNDER_REPL_FACTOR_WARN} partitions"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_clusters() {
  log_message INFO "Listing MSK clusters"
  {
    echo "=== MSK CLUSTERS ==="
  } >> "${OUTPUT_FILE}"

  local total_clusters=0 unhealthy_clusters=0

  list_clusters | while read -r arn; do
    [[ -z "${arn}" ]] && continue
    ((total_clusters++))

    local info
    info=$(describe_cluster "${arn}")

    local name state kafka_version tier broker_count storage_mode volume_size
    name=$(echo "${info}" | jq_safe '.ClusterName')
    state=$(echo "${info}" | jq_safe '.State')
    kafka_version=$(echo "${info}" | jq_safe '.CurrentVersion')
    tier=$(echo "${info}" | jq_safe '.Provisioned.Algorithm || .Serverless.ClusterArn')
    broker_count=$(echo "${info}" | jq '.NumberOfBrokerNodes // .Provisioned.NumberOfBrokerNodes' 2>/dev/null || echo 0)
    storage_mode=$(echo "${info}" | jq_safe '.StorageMode')
    volume_size=$(echo "${info}" | jq_safe '.Provisioned.BrokerNodeGroupInfo.StorageInfo.EbsStorageInfo.VolumeSize')

    {
      echo "Cluster: ${name}"
      echo "  ARN: ${arn}"
      echo "  State: ${state}"
      echo "  Version: ${kafka_version}"
      echo "  Brokers: ${broker_count}"
      echo "  Storage Mode: ${storage_mode}"
      echo "  Volume Size: ${volume_size} GB"
    } >> "${OUTPUT_FILE}"

    if [[ "${state}" != "ACTIVE" ]]; then
      ((unhealthy_clusters++))
      echo "  WARNING: Cluster state is ${state}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Cluster Summary:"
    echo "  Total Clusters: ${total_clusters}"
    echo "  Unhealthy: ${unhealthy_clusters}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_brokers() {
  log_message INFO "Analyzing broker nodes"
  {
    echo "=== BROKER NODES ==="
  } >> "${OUTPUT_FILE}"

  local high_cpu_count=0 high_storage_count=0

  list_clusters | while read -r arn; do
    [[ -z "${arn}" ]] && continue
    local info name
    info=$(describe_cluster "${arn}")
    name=$(echo "${info}" | jq_safe '.ClusterName')

    local nodes
    nodes=$(list_cluster_nodes "${arn}")

    echo "${nodes}" | jq -c '.[]' 2>/dev/null | while read -r node; do
      local broker_id az instance_type storage_info attached_eni node_type
      broker_id=$(echo "${node}" | jq_safe '.BrokerNodeInfo.BrokerId')
      az=$(echo "${node}" | jq_safe '.BrokerNodeInfo.ClientSubnet')
      instance_type=$(echo "${node}" | jq_safe '.BrokerNodeInfo.InstanceType')
      storage_info=$(echo "${node}" | jq_safe '.BrokerNodeInfo.StorageInfo.EbsStorageInfo.VolumeSize')
      attached_eni=$(echo "${node}" | jq_safe '.BrokerNodeInfo.AttachedENIId')
      node_type=$(echo "${node}" | jq_safe '.NodeType')

      # Metrics per broker (using BrokerId dimension)
      local cpu storage_util
      cpu=$(get_metric "${name}" "CpuUser" "Average" "BrokerId" "${broker_id}" || echo "0")
      storage_util=$(get_metric "${name}" "KafkaDataLogsDiskUsed" "Average" "BrokerId" "${broker_id}" || echo "0")

      {
        echo "Broker: ${broker_id} (Cluster: ${name})"
        echo "  AZ/Subnet: ${az}"
        echo "  Instance Type: ${instance_type}"
        echo "  Node Type: ${node_type}"
        echo "  ENI: ${attached_eni}"
        echo "  Storage Size: ${storage_info} GB"
        echo "  CPU (avg): ${cpu}%"
        echo "  Storage Used (avg): ${storage_util}%"
      } >> "${OUTPUT_FILE}"

      if (( cpu >= CPU_THRESHOLD )); then
        ((high_cpu_count++))
        echo "  WARNING: High CPU utilization (${cpu}% >= ${CPU_THRESHOLD}%)" >> "${OUTPUT_FILE}"
      fi
      if (( storage_util >= STORAGE_USED_THRESHOLD )); then
        ((high_storage_count++))
        echo "  WARNING: High storage utilization (${storage_util}% >= ${STORAGE_USED_THRESHOLD}%)" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done

  {
    echo "Broker Summary:"
    echo "  High CPU: ${high_cpu_count}"
    echo "  High Storage: ${high_storage_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_topics_partitions() {
  log_message INFO "Checking topic replication health"
  {
    echo "=== TOPIC REPLICATION HEALTH ==="
  } >> "${OUTPUT_FILE}"

  list_clusters | while read -r arn; do
    [[ -z "${arn}" ]] && continue
    local info name
    info=$(describe_cluster "${arn}")
    name=$(echo "${info}" | jq_safe '.ClusterName')

    local under_repl
    under_repl=$(get_metric "${name}" "UnderReplicatedPartitions" "Average" "ClusterName" "${name}" || echo "0")
    local active_controller
    active_controller=$(get_metric "${name}" "ActiveControllerCount" "Average" "ClusterName" "${name}" || echo "0")
    local offline_partitions
    offline_partitions=$(get_metric "${name}" "OfflinePartitionsCount" "Average" "ClusterName" "${name}" || echo "0")

    {
      echo "Cluster: ${name}"
      echo "  Under-replicated Partitions: ${under_repl}"
      echo "  Active Controller Count: ${active_controller}"
      echo "  Offline Partitions: ${offline_partitions}"
    } >> "${OUTPUT_FILE}"

    if (( under_repl >= UNDER_REPL_FACTOR_WARN )); then
      echo "  WARNING: Under-replicated partitions detected (${under_repl})" >> "${OUTPUT_FILE}"
    fi
    if (( offline_partitions > 0 )); then
      echo "  WARNING: Offline partitions present (${offline_partitions})" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

report_client_metrics() {
  log_message INFO "Checking client connections and throughput"
  {
    echo "=== CLIENT THROUGHPUT ==="
  } >> "${OUTPUT_FILE}"

  list_clusters | while read -r arn; do
    [[ -z "${arn}" ]] && continue
    local info name
    info=$(describe_cluster "${arn}")
    name=$(echo "${info}" | jq_safe '.ClusterName')

    local bytes_in bytes_out conn_count
    bytes_in=$(get_metric "${name}" "BytesInPerSec" "Average" "ClusterName" "${name}" || echo "0")
    bytes_out=$(get_metric "${name}" "BytesOutPerSec" "Average" "ClusterName" "${name}" || echo "0")
    conn_count=$(get_metric "${name}" "ConnectionCount" "Average" "ClusterName" "${name}" || echo "0")

    {
      echo "Cluster: ${name}"
      echo "  Bytes In/s (avg): ${bytes_in}"
      echo "  Bytes Out/s (avg): ${bytes_out}"
      echo "  Connection Count (avg): ${conn_count}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

report_scram_users() {
  log_message INFO "Listing SASL/SCRAM users"
  {
    echo "=== SCRAM USERS ==="
  } >> "${OUTPUT_FILE}"

  list_clusters | while read -r arn; do
    [[ -z "${arn}" ]] && continue
    local users
    users=$(aws kafka list-scram-secrets \
      --cluster-arn "${arn}" \
      --region "${REGION}" \
      --query 'SecretArnList' \
      --output text 2>/dev/null || true)

    {
      echo "Cluster ARN: ${arn}"
      echo "  SCRAM Secret ARNs: ${users:-none}" \
    } >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local clusters="$1"; local unhealthy="$2"; local high_cpu="$3"; local high_storage="$4"; local under_repl="$5"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS MSK Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Clusters", "value": "${clusters}", "short": true},
        {"title": "Unhealthy", "value": "${unhealthy}", "short": true},
        {"title": "High CPU", "value": "${high_cpu}", "short": true},
        {"title": "High Storage", "value": "${high_storage}", "short": true},
        {"title": "Under-Repl Partitions", "value": "${under_repl}", "short": true},
        {"title": "CPU Threshold", "value": "${CPU_THRESHOLD}%", "short": true},
        {"title": "Storage Threshold", "value": "${STORAGE_USED_THRESHOLD}%", "short": true},
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
  log_message INFO "Starting AWS MSK monitoring"
  write_header
  report_clusters
  report_brokers
  report_topics_partitions
  report_client_metrics
  report_scram_users
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local clusters_count unhealthy_count high_cpu high_storage under_repl
  clusters_count=$(list_clusters | wc -w)
  unhealthy_count=$(grep -c "WARNING: Cluster state" "${OUTPUT_FILE}" || echo 0)
  high_cpu=$(grep -c "High CPU" "${OUTPUT_FILE}" || echo 0)
  high_storage=$(grep -c "High storage" "${OUTPUT_FILE}" || echo 0)
  under_repl=$(grep -c "Under-replicated partitions" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${clusters_count}" "${unhealthy_count}" "${high_cpu}" "${high_storage}" "${under_repl}"
  cat "${OUTPUT_FILE}"
}

main "$@"

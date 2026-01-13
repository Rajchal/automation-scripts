#!/bin/bash

################################################################################
# AWS Redshift Cluster Monitor
# Monitors Redshift clusters for status, snapshot backups, node health, and query performance
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/redshift-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-redshift-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_clusters() {
  aws redshift describe-clusters --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_snapshots() {
  local cluster_id="$1"
  aws redshift describe-cluster-snapshots --cluster-identifier "${cluster_id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_cluster_events() {
  local source_identifier="$1"
  aws redshift describe-events --source-identifier "${source_identifier}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_wlm_queries() {
  # Uses CloudWatch metrics for WLM and queue depth if available
  local cluster="$1"; local queue="$2"; local period=300
  aws cloudwatch get-metric-statistics --namespace AWS/Redshift --metric-name "QueryDuration" --dimensions Name=ClusterIdentifier,Value="${cluster}" --start-time "$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period ${period} --statistics Maximum --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Redshift Cluster Monitor"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_clusters() {
  log_message INFO "Listing Redshift clusters"
  echo "=== Redshift Clusters ===" >> "${OUTPUT_FILE}"

  local clusters
  clusters=$(list_clusters)
  echo "${clusters}" | jq -c '.Clusters[]?' 2>/dev/null | while read -r c; do
    local id status node_count node_type master_username endpoint
    id=$(echo "${c}" | jq_safe '.ClusterIdentifier')
    status=$(echo "${c}" | jq_safe '.ClusterStatus')
    node_count=$(echo "${c}" | jq_safe '.NumberOfNodes')
    node_type=$(echo "${c}" | jq_safe '.NodeType')
    master_username=$(echo "${c}" | jq_safe '.MasterUsername')
    endpoint=$(echo "${c}" | jq -r '.Endpoint.Address' 2>/dev/null || echo '')

    echo "Cluster: ${id}" >> "${OUTPUT_FILE}"
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"
    echo "  Nodes: ${node_count} (${node_type})" >> "${OUTPUT_FILE}"
    echo "  Endpoint: ${endpoint}" >> "${OUTPUT_FILE}"

    # Recent snapshots
    local snaps
    snaps=$(describe_snapshots "${id}")
    local recent_snap
    recent_snap=$(echo "${snaps}" | jq -r '.Snapshots | sort_by(.SnapshotCreateTime) | last(.[]?) | .SnapshotCreateTime' 2>/dev/null || echo 'none')
    echo "  Most recent snapshot: ${recent_snap}" >> "${OUTPUT_FILE}"

    # Recent events
    local events
    events=$(get_cluster_events "${id}")
    echo "  Recent events:" >> "${OUTPUT_FILE}"
    echo "${events}" | jq -c '.Events[]? | {Date: .EventTime, Message: .Message, Severity: .Severity}' 2>/dev/null | head -n 10 | while read -r ev; do
      echo "    - $(echo "${ev}" | jq -r '.Date') : $(echo "${ev}" | jq -r '.Message')" >> "${OUTPUT_FILE}"
    done

    # WLM / Query metrics (approx)
    local qmetrics
    qmetrics=$(get_wlm_queries "${id}" "")
    local max_qdur
    max_qdur=$(echo "${qmetrics}" | jq -r '.Datapoints[]?.Maximum' 2>/dev/null | sort -n | tail -n1 || echo 0)
    echo "  Max query duration (15m window): ${max_qdur}s" >> "${OUTPUT_FILE}"

    if [[ "${status}" != "available" ]]; then
      echo "  WARNING: Cluster ${id} status=${status}" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Redshift Summary:"
    echo "  Clusters checked: $(echo "${clusters}" | jq '.Clusters | length' 2>/dev/null || echo 0)"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local msg="$1"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Redshift Monitor Alert",
  "attachments": [
    {"color": "warning", "text": "${msg}"}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting Redshift cluster monitor"
  write_header
  audit_clusters
  log_message INFO "Redshift monitor complete. Report: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

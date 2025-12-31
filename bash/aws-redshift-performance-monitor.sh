#!/bin/bash

################################################################################
# AWS Redshift Performance & Posture Monitor
# - Inventories Redshift clusters and nodes
# - Checks encryption, logging, public accessibility, snapshot retention
# - Pulls CloudWatch metrics (CPUUtilization, DatabaseConnections,
#   ReadIOPS, WriteIOPS, NetworkReceiveThroughput, NetworkTransmitThroughput,
#   PercentageDiskSpaceUsed, QueryDuration (custom), WLMQueueLength)
# - Flags clusters exceeding thresholds and sends Slack/email alerts
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/redshift-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/redshift-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
CPU_WARN_PCT="${CPU_WARN_PCT:-80}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
CONNECTIONS_WARN="${CONNECTIONS_WARN:-500}"
QUERY_LATENCY_WARN_MS="${QUERY_LATENCY_WARN_MS:-2000}"
WLM_QUEUE_WARN="${WLM_QUEUE_WARN:-5}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Counters
TOTAL_CLUSTERS=0
CLUSTERS_WITH_ISSUES=0
HIGH_CPU=0
HIGH_DISK=0
HIGH_CONN=0
HIGH_QUERY_LATENCY=0
WLM_QUEUE_ISSUES=0

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
      "title": "AWS Redshift Monitor",
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
    echo "AWS Redshift Performance & Posture Monitor"
    echo "==========================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Window: ${LOOKBACK_HOURS}h"
    echo "Thresholds: CPU>${CPU_WARN_PCT}%, Disk%>${DISK_WARN_PCT}%, Connections>${CONNECTIONS_WARN}, QueryLatency>${QUERY_LATENCY_WARN_MS}ms, WLM Queue>${WLM_QUEUE_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws_cmd redshift describe-clusters --region "${REGION}" --output json 2>/dev/null || echo '{"Clusters":[]}'
}

get_metric() {
  local cluster="$1" metric="$2" stat_type="${3:-Average}" dim_name="ClusterIdentifier"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Redshift \
    --metric-name "$metric" \
    --dimensions Name="${dim_name}",Value="$cluster" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

avg_from_datapoints() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
max_from_datapoints() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }

record_issue() { ISSUES+=("$1"); }

analyze_cluster() {
  local cjson="$1"
  local cid node_type encrypted publicly_accessible logging_enabled automated_snapshot_retention
  cid=$(echo "${cjson}" | jq_safe '.ClusterIdentifier')
  node_type=$(echo "${cjson}" | jq_safe '.NodeType')
  encrypted=$(echo "${cjson}" | jq_safe '.Encrypted')
  publicly_accessible=$(echo "${cjson}" | jq_safe '.PubliclyAccessible')
  logging_enabled=$(echo "${cjson}" | jq_safe '.LoggingEnabled')
  automated_snapshot_retention=$(echo "${cjson}" | jq_safe '.AutomatedSnapshotRetentionPeriod')

  TOTAL_CLUSTERS=$((TOTAL_CLUSTERS + 1))
  log_message INFO "Analyzing Redshift cluster ${cid}"

  {
    echo "Cluster: ${cid}"
    echo "  Node Type: ${node_type}"
    echo "  Encrypted: ${encrypted}"
    echo "  Publicly Accessible: ${publicly_accessible}"
    echo "  Logging Enabled: ${logging_enabled}"
    echo "  Snapshot Retention Days: ${automated_snapshot_retention}"
  } >> "${OUTPUT_FILE}"

  # Metrics
  local cpu conn read_iops write_iops net_rx net_tx disk_pct
  cpu=$(get_metric "${cid}" "CPUUtilization" "Average" | avg_from_datapoints)
  conn=$(get_metric "${cid}" "DatabaseConnections" "Average" | avg_from_datapoints)
  read_iops=$(get_metric "${cid}" "ReadIOPS" "Sum" | max_from_datapoints)
  write_iops=$(get_metric "${cid}" "WriteIOPS" "Sum" | max_from_datapoints)
  net_rx=$(get_metric "${cid}" "NetworkReceiveThroughput" "Average" | avg_from_datapoints)
  net_tx=$(get_metric "${cid}" "NetworkTransmitThroughput" "Average" | avg_from_datapoints)
  disk_pct=$(get_metric "${cid}" "PercentageDiskSpaceUsed" "Average" | avg_from_datapoints)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    CPU (avg): ${cpu}%"
    echo "    Connections (avg): ${conn}"
    echo "    ReadIOPS (max): ${read_iops}"
    echo "    WriteIOPS (max): ${write_iops}"
    echo "    NetRx (avg KB/s): ${net_rx}"
    echo "    NetTx (avg KB/s): ${net_tx}"
    echo "    DiskUsed% (avg): ${disk_pct}%"
  } >> "${OUTPUT_FILE}"

  local issue=0
  if (( $(echo "${cpu} > ${CPU_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    HIGH_CPU=$((HIGH_CPU + 1))
    issue=1
    record_issue "Redshift ${cid} CPU ${cpu}% > ${CPU_WARN_PCT}%"
  fi
  if (( $(echo "${disk_pct} > ${DISK_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    HIGH_DISK=$((HIGH_DISK + 1))
    issue=1
    record_issue "Redshift ${cid} disk usage ${disk_pct}% > ${DISK_WARN_PCT}%"
  fi
  if (( $(echo "${conn} > ${CONNECTIONS_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    HIGH_CONN=$((HIGH_CONN + 1))
    issue=1
    record_issue "Redshift ${cid} connections ${conn} > ${CONNECTIONS_WARN}"
  fi

  # Query latency and WLM queue length (may require custom metrics)
  local qlat wlmq
  qlat=$(get_metric "${cid}" "QueryDuration" "Maximum" | max_from_datapoints)
  wlmq=$(get_metric "${cid}" "WLMQueueLength" "Maximum" | max_from_datapoints)

  if (( $(echo "${qlat}*1000 > ${QUERY_LATENCY_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    HIGH_QUERY_LATENCY=$((HIGH_QUERY_LATENCY + 1))
    issue=1
    record_issue "Redshift ${cid} query latency ${qlat}s > ${QUERY_LATENCY_WARN_MS}ms"
  fi
  if (( $(echo "${wlmq} > ${WLM_QUEUE_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    WLM_QUEUE_ISSUES=$((WLM_QUEUE_ISSUES + 1))
    issue=1
    record_issue "Redshift ${cid} WLM queue length ${wlmq} > ${WLM_QUEUE_WARN}"
  fi

  # Posture checks
  if [[ "${encrypted}" != "true" ]]; then
    issue=1
    record_issue "Redshift ${cid} encryption not enabled"
  fi
  if [[ "${logging_enabled}" != "true" ]]; then
    issue=1
    record_issue "Redshift ${cid} logging not enabled"
  fi
  if [[ "${publicly_accessible}" == "true" ]]; then
    issue=1
    record_issue "Redshift ${cid} is publicly accessible"
  fi

  if (( issue )); then
    CLUSTERS_WITH_ISSUES=$((CLUSTERS_WITH_ISSUES + 1))
    echo "  STATUS: ⚠️ ISSUES DETECTED" >> "${OUTPUT_FILE}"
  else
    echo "  STATUS: ✓ OK" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local clusters_json
  clusters_json=$(list_clusters)
  local ccount
  ccount=$(echo "${clusters_json}" | jq '.Clusters | length' 2>/dev/null || echo 0)

  if [[ "${ccount}" == "0" ]]; then
    log_message WARN "No Redshift clusters found"
    echo "No Redshift clusters found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Clusters: ${ccount}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  echo "${clusters_json}" | jq -c '.Clusters[]' 2>/dev/null | while read -r c; do
    analyze_cluster "${c}"
  done

  {
    echo "Summary"
    echo "-------"
    echo "Total Clusters: ${TOTAL_CLUSTERS}"
    echo "Clusters with Issues: ${CLUSTERS_WITH_ISSUES}"
    echo "High CPU: ${HIGH_CPU}"
    echo "High Disk: ${HIGH_DISK}"
    echo "High Connections: ${HIGH_CONN}"
    echo "High Query Latency: ${HIGH_QUERY_LATENCY}"
    echo "WLM Queue Issues: ${WLM_QUEUE_ISSUES}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "Redshift Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "Redshift Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

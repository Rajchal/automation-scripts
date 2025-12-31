
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/msk-cluster-health-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/msk-cluster-health-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
UNDER_REPLICATED_WARN="${UNDER_REPLICATED_WARN:-1}"
OFFLINE_PARTITIONS_WARN="${OFFLINE_PARTITIONS_WARN:-1}"
UNCLEAN_LEADER_WARN="${UNCLEAN_LEADER_WARN:-1}"
BROKER_DISK_WARN_PCT="${BROKER_DISK_WARN_PCT:-85}"
ACTIVE_CONTROLLER_WARN="${ACTIVE_CONTROLLER_WARN:-1}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Counters
TOTAL_CLUSTERS=0
CLUSTERS_WITH_ISSUES=0
CLUSTERS_UNDER_REPLICATED=0
CLUSTERS_OFFLINE_PARTS=0
CLUSTERS_UNCLEAN_LEADERS=0
CLUSTERS_HIGH_DISK=0

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
  local message="$1"; local severity="${2:-INFO}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in CRITICAL) color="danger";; WARNING) color="warning";; INFO) color="good";; *) color="good";; esac
  local payload
  payload=$(cat <<EOF
{ "attachments":[{"color":"${color}","title":"AWS MSK Alert","text":"${message}","ts":$(date +%s)}] }
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() { local subject="$1"; local body="$2"; [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null && return; echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true; }

write_header() {
  {
    echo "AWS MSK Cluster Health Monitor"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Window: ${LOOKBACK_HOURS}h"
    echo "Thresholds: UnderReplicated>${UNDER_REPLICATED_WARN}, OfflineParts>${OFFLINE_PARTITIONS_WARN}, UncleanLeaders>${UNCLEAN_LEADER_WARN}, BrokerDisk%>${BROKER_DISK_WARN_PCT}" 
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws_cmd kafka list-clusters --region "${REGION}" --output json 2>/dev/null || echo '{"ClusterInfoList":[]}'
}

describe_cluster() {
  local arn="$1"
  aws_cmd kafka describe-cluster --cluster-arn "$arn" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_metric() {
  local cluster_id="$1" metric="$2" stat_type="${3:-Sum}" dim_name="Cluster Name"
  # MSK metrics are published under AWS/Kafka - dimension names vary; pass the cluster ARN or broker id as needed
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Kafka \
    --metric-name "$metric" \
    --dimensions Name=ClusterArn,Value="$cluster_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

sum_datapoints() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {print int(s)}'; }
max_datapoints() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END{print (NR==0?0:m)}'; }
avg_datapoints() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END{if(c>0) printf "%.2f", s/c; else print "0"}'; }

record_issue() { ISSUES+=("$1"); }

analyze_cluster() {
  local cjson="$1"
  local arn cluster_name cluster_type state broker_nodes
  arn=$(echo "${cjson}" | jq_safe '.ClusterArn')
  cluster_name=$(echo "${cjson}" | jq_safe '.ClusterName')
  cluster_type=$(echo "${cjson}" | jq_safe '.ClusterType')
  state=$(echo "${cjson}" | jq_safe '.State')
  broker_nodes=$(echo "${cjson}" | jq -r '.BrokerNodeGroupInfo | .KafkaVersion // empty' 2>/dev/null || echo "")

  TOTAL_CLUSTERS=$((TOTAL_CLUSTERS+1))
  log_message INFO "Analyzing MSK cluster ${cluster_name}"

  {
    echo "Cluster: ${cluster_name}"
    echo "  ARN: ${arn}"
    echo "  Type: ${cluster_type}"
    echo "  State: ${state}"
    echo "  Broker Info: ${broker_nodes}"
  } >> "${OUTPUT_FILE}"

  # Metrics
  local under_repl offline_parts unclean leader_count broker_disk_pct active_controller
  under_repl=$(get_metric "${arn}" "UnderReplicatedPartitions" "Sum" | sum_datapoints)
  offline_parts=$(get_metric "${arn}" "OfflinePartitionsCount" "Sum" | sum_datapoints)
  unclean=$(get_metric "${arn}" "UncleanLeaderElectionsPerSec" "Sum" | sum_datapoints)
  broker_disk_pct=$(get_metric "${arn}" "BrokerStorageUtilization" "Average" | avg_datapoints)
  active_controller=$(get_metric "${arn}" "ActiveControllerCount" "Maximum" | max_datapoints)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    UnderReplicatedPartitions: ${under_repl}"
    echo "    OfflinePartitions: ${offline_parts}"
    echo "    UncleanLeaderElections (sum): ${unclean}"
    echo "    Broker Disk Utilization (avg%): ${broker_disk_pct}"
    echo "    Active Controller Count (max): ${active_controller}"
  } >> "${OUTPUT_FILE}"

  local issue=0
  if (( under_repl >= UNDER_REPLICATED_WARN )); then
    CLUSTERS_UNDER_REPLICATED=$((CLUSTERS_UNDER_REPLICATED+1))
    issue=1
    record_issue "MSK ${cluster_name} has ${under_repl} under-replicated partitions"
  fi
  if (( offline_parts >= OFFLINE_PARTITIONS_WARN )); then
    CLUSTERS_OFFLINE_PARTS=$((CLUSTERS_OFFLINE_PARTS+1))
    issue=1
    record_issue "MSK ${cluster_name} has ${offline_parts} offline partitions"
  fi
  if (( unclean >= UNCLEAN_LEADER_WARN )); then
    CLUSTERS_UNCLEAN_LEADERS=$((CLUSTERS_UNCLEAN_LEADERS+1))
    issue=1
    record_issue "MSK ${cluster_name} observed ${unclean} unclean leader elections"
  fi
  if (( $(echo "${broker_disk_pct} > ${BROKER_DISK_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    CLUSTERS_HIGH_DISK=$((CLUSTERS_HIGH_DISK+1))
    issue=1
    record_issue "MSK ${cluster_name} broker disk utilization ${broker_disk_pct}% > ${BROKER_DISK_WARN_PCT}%"
  fi
  if (( active_controller < ACTIVE_CONTROLLER_WARN )); then
    issue=1
    record_issue "MSK ${cluster_name} has no active controller (count ${active_controller})"
  fi

  if (( issue )); then
    CLUSTERS_WITH_ISSUES=$((CLUSTERS_WITH_ISSUES+1))
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
  local count
  count=$(echo "${clusters_json}" | jq '.ClusterInfoList | length' 2>/dev/null || echo 0)

  if [[ "${count}" == "0" ]]; then
    log_message WARN "No MSK clusters found"
    echo "No MSK clusters found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total Clusters: ${count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  echo "${clusters_json}" | jq -c '.ClusterInfoList[]' 2>/dev/null | while read -r c; do
    analyze_cluster "${c}"
  done

  {
    echo "Summary"
    echo "-------"
    echo "Total Clusters: ${TOTAL_CLUSTERS}"
    echo "Clusters with Issues: ${CLUSTERS_WITH_ISSUES}"
    echo "Under-replicated clusters: ${CLUSTERS_UNDER_REPLICATED}"
    echo "Clusters with Offline Partitions: ${CLUSTERS_OFFLINE_PARTS}"
    echo "Clusters with Unclean Leaders: ${CLUSTERS_UNCLEAN_LEADERS}"
    echo "Clusters with High Disk: ${CLUSTERS_HIGH_DISK}"
    echo ""
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "MSK Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "MSK Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

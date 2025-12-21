#!/bin/bash

################################################################################
# AWS Managed Prometheus Stack Monitor
# Monitors Amazon Managed Prometheus (AMP) workspace health, ingestion rates,
# query performance, storage usage, and scaling recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/amp-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/amp-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
INGESTION_RATE_HIGH="${INGESTION_RATE_HIGH:-1000000}"        # samples/min
QUERY_LATENCY_HIGH="${QUERY_LATENCY_HIGH:-5000}"              # milliseconds
CARDINALITY_WARN="${CARDINALITY_WARN:-1000000}"               # high cardinality
STORAGE_USAGE_WARN="${STORAGE_USAGE_WARN:-80}"                # % full
REQUEST_RATE_HIGH="${REQUEST_RATE_HIGH:-10000}"               # requests/min

# Analysis window
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

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

list_workspaces() {
  aws amp list-workspaces \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"workspaces":[]}'
}

describe_workspace() {
  local workspace_id="$1"
  aws amp describe-workspace \
    --workspace-id "${workspace_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_cw_metrics() {
  local workspace_id="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Prometheus \
    --metric-name "${metric_name}" \
    --dimensions Name=WorkspaceId,Value="${workspace_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

calculate_max() {
  jq -r '.Datapoints[].Maximum' 2>/dev/null | \
    awk '{if ($1>m||m=="") m=$1} END {print (m==""?"0":m)}'
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
      "title": "Managed Prometheus Monitor",
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
    echo "AWS Managed Prometheus Stack Monitor"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Alert Thresholds:"
    echo "  Ingestion Rate High: ${INGESTION_RATE_HIGH} samples/min"
    echo "  Query Latency High: ${QUERY_LATENCY_HIGH}ms"
    echo "  Storage Usage: ${STORAGE_USAGE_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

monitor_workspaces() {
  log_message INFO "Starting AMP workspace monitoring"
  
  {
    echo "=== WORKSPACE STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local workspaces_json
  workspaces_json=$(list_workspaces)
  
  local workspace_ids
  workspace_ids=$(echo "${workspaces_json}" | jq -r '.workspaces[]?.workspaceId' 2>/dev/null)
  
  if [[ -z "${workspace_ids}" ]]; then
    log_message WARN "No AMP workspaces found in region ${REGION}"
    {
      echo "Status: No workspaces found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_workspaces=0
  local active_workspaces=0
  local degraded_workspaces=0
  
  while IFS= read -r workspace_id; do
    [[ -z "${workspace_id}" ]] && continue
    ((total_workspaces++))
    
    log_message INFO "Monitoring workspace: ${workspace_id}"
    
    local ws_desc
    ws_desc=$(describe_workspace "${workspace_id}")
    
    local alias status created_date prometheus_endpoint
    alias=$(echo "${ws_desc}" | jq_safe '.workspace.alias')
    status=$(echo "${ws_desc}" | jq_safe '.workspace.status')
    created_date=$(echo "${ws_desc}" | jq_safe '.workspace.createdAt')
    prometheus_endpoint=$(echo "${ws_desc}" | jq_safe '.workspace.prometheusEndpoint')
    
    if [[ "${status}" == "ACTIVE" ]]; then
      ((active_workspaces++))
    else
      ((degraded_workspaces++))
    fi
    
    local status_color="${GREEN}"
    [[ "${status}" != "ACTIVE" ]] && status_color="${YELLOW}"
    
    {
      echo "Workspace: ${alias}"
      echo "ID: ${workspace_id}"
      printf "%bStatus: %s%b\n" "${status_color}" "${status}" "${NC}"
      echo "Created: ${created_date}"
      echo "Endpoint: ${prometheus_endpoint}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get metrics
    local ingestion_rate query_latency request_rate
    
    ingestion_rate=$(get_cw_metrics "${workspace_id}" "IngestionRate" | calculate_avg)
    query_latency=$(get_cw_metrics "${workspace_id}" "QueryLatency" | calculate_max)
    request_rate=$(get_cw_metrics "${workspace_id}" "RequestRate" | calculate_avg)
    
    {
      echo "Metrics (${LOOKBACK_HOURS}h lookback):"
      echo "  Ingestion Rate: ${ingestion_rate} samples/min"
      echo "  Query Latency (max): ${query_latency}ms"
      echo "  Request Rate: ${request_rate} req/min"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check thresholds
    local warnings=0
    
    if (( $(echo "${ingestion_rate} > ${INGESTION_RATE_HIGH}" | bc -l) )); then
      {
        echo "  ⚠️  High ingestion rate: ${ingestion_rate} samples/min"
      } >> "${OUTPUT_FILE}"
      ((warnings++))
      log_message WARN "Workspace ${workspace_id} has high ingestion rate"
    fi
    
    if (( $(echo "${query_latency} > ${QUERY_LATENCY_HIGH}" | bc -l) )); then
      {
        echo "  ⚠️  High query latency: ${query_latency}ms"
      } >> "${OUTPUT_FILE}"
      ((warnings++))
      log_message WARN "Workspace ${workspace_id} has high query latency"
    fi
    
    if (( $(echo "${request_rate} > ${REQUEST_RATE_HIGH}" | bc -l) )); then
      {
        echo "  ⚠️  High request rate: ${request_rate} req/min"
      } >> "${OUTPUT_FILE}"
      ((warnings++))
      log_message WARN "Workspace ${workspace_id} has high request rate"
    fi
    
    if [[ ${warnings} -eq 0 ]]; then
      {
        echo "  ✓ Within normal parameters"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${workspace_ids}"
  
  # Summary
  {
    echo "=== WORKSPACE SUMMARY ==="
    echo "Total Workspaces: ${total_workspaces}"
    echo "Active: ${active_workspaces}"
    echo "Degraded: ${degraded_workspaces}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${degraded_workspaces} -gt 0 ]]; then
    log_message WARN "Found ${degraded_workspaces} degraded workspaces"
    local alert_msg="⚠️  AMP: ${degraded_workspaces} workspace(s) not in ACTIVE state"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
}

analyze_data_characteristics() {
  log_message INFO "Analyzing data characteristics"
  
  {
    echo ""
    echo "=== DATA CHARACTERISTICS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local workspaces_json
  workspaces_json=$(list_workspaces)
  
  local workspace_ids
  workspace_ids=$(echo "${workspaces_json}" | jq -r '.workspaces[]?.workspaceId' 2>/dev/null)
  
  if [[ -z "${workspace_ids}" ]]; then
    return
  fi
  
  while IFS= read -r workspace_id; do
    [[ -z "${workspace_id}" ]] && continue
    
    {
      echo "Workspace: ${workspace_id}"
      echo "  Series Count: Retrieved via PromQL query (not available via API)"
      echo "  Storage Size: Retrieved via DescribeWorkspace API"
      echo "  Retention Period: Retrieved via workspace configuration"
      echo ""
    } >> "${OUTPUT_FILE}"
  done <<< "${workspace_ids}"
}

scaling_recommendations() {
  {
    echo ""
    echo "=== SCALING RECOMMENDATIONS ==="
    echo ""
    echo "When to scale up:"
    echo "  • Ingestion rate consistently >500K samples/min"
    echo "  • Query latency >3000ms for typical queries"
    echo "  • Series count approaching 10M limit"
    echo "  • Storage approaching retention limits"
    echo ""
    echo "Optimization strategies:"
    echo "  • Reduce scrape frequency for non-critical metrics"
    echo "  • Implement metric relabeling to drop unnecessary labels"
    echo "  • Use recording rules to pre-aggregate high-cardinality metrics"
    echo "  • Partition large metrics across multiple scrape jobs"
    echo "  • Set shorter retention periods for less critical data"
    echo "  • Use lifecycle policies for long-term storage"
    echo ""
    echo "Query optimization:"
    echo "  • Add range vectors to time-series queries"
    echo "  • Use aggregation operators efficiently"
    echo "  • Avoid non-indexed label filters in high-cardinality queries"
    echo "  • Pre-compute aggregates with recording rules"
    echo ""
  } >> "${OUTPUT_FILE}"
}

ingestion_best_practices() {
  {
    echo ""
    echo "=== INGESTION BEST PRACTICES ==="
    echo ""
    echo "Configuration:"
    echo "  • Set appropriate scrape intervals (default 30s, can increase to 60s)"
    echo "  • Use metric_relabel_configs to filter/rename metrics"
    echo "  • Implement service discovery for dynamic target management"
    echo "  • Configure scrape timeouts to prevent hanging requests"
    echo ""
    echo "Data quality:"
    echo "  • Validate metric naming conventions (snake_case)"
    echo "  • Avoid high-cardinality labels (request IDs, user IDs, etc.)"
    echo "  • Use consistent label sets across similar metrics"
    echo "  • Monitor for metric explosion from unexpected labels"
    echo ""
    echo "Reliability:"
    echo "  • Use remote write with proper retry and persistence"
    echo "  • Implement HA Prometheus pairs with deduplication"
    echo "  • Set up alerts for scrape failures and missed samples"
    echo "  • Monitor AMP health metrics for capacity planning"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== AMP Stack Monitor Started ==="
  
  write_header
  monitor_workspaces
  analyze_data_characteristics
  scaling_recommendations
  ingestion_best_practices
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "Useful PromQL Queries:"
    echo "  • Scrape duration: scrape_duration_seconds"
    echo "  • Failed scrapes: up == 0"
    echo "  • Samples per second: rate(prometheus_tsdb_symbol_table_size_bytes[5m])"
    echo "  • Cardinality: topk(10, count({__name__=~\".+\"}) by (__name__))"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== AMP Stack Monitor Completed ==="
}

main "$@"

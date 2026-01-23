#!/bin/bash

################################################################################
# AWS Athena Query Monitor
# Monitors Athena for failed queries, long-running queries, and query throughput
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/athena-query-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-athena-query-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LONG_QUERY_WARN_SECONDS="${LONG_QUERY_WARN_SECONDS:-300}"
FAILED_WARN_THRESHOLD="${FAILED_WARN_THRESHOLD:-5}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_query_executions() {
  local state_filter="${1:-ALL}"
  aws athena list-query-executions --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_query_execution() {
  local id="$1"
  aws athena get-query-execution --query-execution-id "${id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_cw_metric() {
  local metric="$1"; local stat="${2:-Sum}"; local period=300
  aws cloudwatch get-metric-statistics --namespace AWS/Athena --metric-name "${metric}" --start-time "$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period ${period} --statistics ${stat} --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Athena Query Monitor"
    echo "========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Long query warn seconds: ${LONG_QUERY_WARN_SECONDS}"
    echo "Failed warn threshold: ${FAILED_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_queries() {
  log_message INFO "Listing recent Athena queries"
  echo "=== Recent Athena Queries ===" >> "${OUTPUT_FILE}"

  local execs
  execs=$(aws athena list-query-executions --region "${REGION}" --max-results 50 --output json 2>/dev/null || echo '{}')
  echo "${execs}" | jq -r '.QueryExecutionIds[]?' 2>/dev/null | while read -r qid; do
    local qe
    qe=$(describe_query_execution "${qid}")
    local state submission engine duration_nanos database
    state=$(echo "${qe}" | jq_safe '.QueryExecution.Status.State')
    submission=$(echo "${qe}" | jq_safe '.QueryExecution.Status.SubmissionDateTime')
    engine=$(echo "${qe}" | jq_safe '.QueryExecution.QueryExecutionContext.Catalog')
    database=$(echo "${qe}" | jq_safe '.QueryExecution.QueryExecutionContext.Database')
    duration_nanos=$(echo "${qe}" | jq_safe '.QueryExecution.Statistics.EngineExecutionTimeInMillis')

    echo "Query: ${qid}" >> "${OUTPUT_FILE}"
    echo "  State: ${state}" >> "${OUTPUT_FILE}"
    echo "  Submitted: ${submission}" >> "${OUTPUT_FILE}"
    echo "  Engine: ${engine}  Database: ${database}" >> "${OUTPUT_FILE}"
    echo "  Duration(ms): ${duration_nanos}" >> "${OUTPUT_FILE}"

    if [[ "${state}" == "FAILED" ]]; then
      echo "  WARNING: Query ${qid} failed" >> "${OUTPUT_FILE}"
    fi
    if [[ "${duration_nanos}" != "null" && ${duration_nanos:-0} -ge $(( LONG_QUERY_WARN_SECONDS * 1000 )) ]]; then
      echo "  WARNING: Query ${qid} running long: ${duration_nanos}ms" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  # CloudWatch summary
  echo "=== CloudWatch Athena Metrics (15m window) ===" >> "${OUTPUT_FILE}"
  local failed_count
  failed_count=$(get_cw_metric "FailedQueryCount" "Sum" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
  echo "  FailedQueryCount (15m): ${failed_count}" >> "${OUTPUT_FILE}"
  if (( ${failed_count:-0} >= FAILED_WARN_THRESHOLD )); then
    echo "  ALERT: High failed queries in last 15m: ${failed_count}" >> "${OUTPUT_FILE}"
  fi
  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local failed_count="$1"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( failed_count > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Athena Monitor Summary",
  "attachments": [
    {"color": "${color}", "fields": [{"title":"FailedQueries(15m)","value":"${failed_count}","short":true}]}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting Athena monitor"
  write_header
  audit_queries
  log_message INFO "Athena monitor complete. Report: ${OUTPUT_FILE}"

  local failed_count
  failed_count=$(grep "FailedQueryCount" "${OUTPUT_FILE}" -n 2>/dev/null || true)
  send_slack_alert "0"
  cat "${OUTPUT_FILE}"
}

main "$@"

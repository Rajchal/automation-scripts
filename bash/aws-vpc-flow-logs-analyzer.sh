#!/bin/bash

################################################################################
# AWS VPC Flow Logs Analyzer
# Audits VPC flow log coverage, inspects delivery status, and samples CloudWatch
# Logs Insights for reject rates and top talkers. Produces a text report,
# supports thresholds, logging, and Slack/email alerts.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/vpc-flow-logs-analyzer-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/vpc-flow-logs-analyzer.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
INSIGHTS_LIMIT="${INSIGHTS_LIMIT:-50}"               # max rows per query result
REJECT_RATE_WARN_PCT="${REJECT_RATE_WARN_PCT:-5}"   # % of rejects vs total
TOP_TALKER_BYTES_WARN="${TOP_TALKER_BYTES_WARN:-500000000}" # bytes threshold
QUERY_POLL_SECONDS="${QUERY_POLL_SECONDS:-2}"
QUERY_POLL_ATTEMPTS="${QUERY_POLL_ATTEMPTS:-20}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_VPCS=0
VPCS_WITH_FLOWLOGS=0
VPCS_MISSING_FLOWLOGS=0
VPCS_REJECT_ALERTS=0
VPCS_TOPTALKER_ALERTS=0

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
      "title": "AWS VPC Flow Logs Alert",
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
    echo "AWS VPC Flow Logs Analyzer"
    echo "=========================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Reject Rate Warning: > ${REJECT_RATE_WARN_PCT}%"
    echo "  Top Talker Bytes Warning: > ${TOP_TALKER_BYTES_WARN} bytes"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_vpcs() {
  aws_cmd ec2 describe-vpcs \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Vpcs":[]}'
}

get_flow_logs_for_vpc() {
  local vpc_id="$1"
  aws_cmd ec2 describe-flow-logs \
    --filter "Name=resource-id,Values=${vpc_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"FlowLogs":[]}'
}

start_logs_query() {
  local log_group="$1" query="$2"
  local start_ts end_ts
  start_ts=$(date -d "${LOOKBACK_HOURS} hours ago" +%s)
  end_ts=$(date +%s)
  aws_cmd logs start-query \
    --log-group-name "${log_group}" \
    --start-time "${start_ts}" \
    --end-time "${end_ts}" \
    --limit "${INSIGHTS_LIMIT}" \
    --query-string "$query" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

poll_query() {
  local query_id="$1"
  local attempts=0
  while (( attempts < QUERY_POLL_ATTEMPTS )); do
    local resp status
    resp=$(aws_cmd logs get-query-results --query-id "${query_id}" --region "${REGION}" --output json 2>/dev/null || echo '{}')
    status=$(echo "${resp}" | jq_safe '.status')
    case "${status}" in
      Complete) echo "${resp}"; return 0 ;;
      Cancelled|Failed|Timeout) echo "${resp}"; return 1 ;;
      *) sleep "${QUERY_POLL_SECONDS}" ;;
    esac
    attempts=$((attempts + 1))
  done
  return 1
}

run_logs_query() {
  local log_group="$1" query="$2"
  local start_resp query_id
  start_resp=$(start_logs_query "${log_group}" "$query")
  query_id=$(echo "${start_resp}" | jq_safe '.queryId')
  [[ -z "${query_id}" || "${query_id}" == "null" ]] && { echo '{}'; return 1; }
  poll_query "${query_id}" || { echo '{}'; return 1; }
}

extract_field_from_result() {
  local json="$1" field_name="$2"
  echo "${json}" | jq -r "\(.results[]? | reduce .[] as $f ({}; .[$f.field]=$f.value) | .${field_name} // empty)" 2>/dev/null
}

first_number_or_zero() {
  local val
  val=$(echo "$1" | head -n1)
  [[ -z "${val}" ]] && { echo 0; return; }
  if [[ "${val}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    echo "${val}" | awk '{printf "%f", $1}'
  else
    echo 0
  fi
}

format_top_entries() {
  local json="$1"
  echo "${json}" | jq -r '.results[]? | reduce .[] as $f ({}; .[$f.field]=$f.value) |
    "\(.srcAddr // "-") -> \(.dstAddr // "-"):\(.dstPort // "-") proto=\(.protocol // "-") bytes=\(.bytes // "0") flows=\(.flows // "0")"' 2>/dev/null | head -n 5
}

format_reject_entries() {
  local json="$1"
  echo "${json}" | jq -r '.results[]? | reduce .[] as $f ({}; .[$f.field]=$f.value) |
    "\(.srcAddr // "-") -> \(.dstAddr // "-"):\(.dstPort // "-") proto=\(.protocol // "-") bytes=\(.bytes // "0") rejects=\(.rejects // "0")"' 2>/dev/null | head -n 5
}

record_issue() {
  ISSUES+=("$1")
}

analyze_log_group() {
  local vpc_id="$1" vpc_name="$2" log_group="$3"
  log_message INFO "Running Insights for ${vpc_id} (${vpc_name}) on ${log_group}"

  local counts_json rejects_json talkers_json
  counts_json=$(run_logs_query "${log_group}" 'stats count(*) as count by action | sort by count desc') || counts_json='{}'
  rejects_json=$(run_logs_query "${log_group}" 'filter action="REJECT" | stats sum(bytes) as bytes, count(*) as rejects by srcAddr, dstAddr, dstPort, protocol | sort by bytes desc | limit 50') || rejects_json='{}'
  talkers_json=$(run_logs_query "${log_group}" 'stats sum(bytes) as bytes, count(*) as flows by srcAddr, dstAddr, dstPort, protocol | sort by bytes desc | limit 50') || talkers_json='{}'

  local total_count reject_count reject_rate top_talker_bytes top_reject_bytes
  total_count=$(echo "${counts_json}" | jq -r '.results[]? | reduce .[] as $f ({}; .[$f.field]=$f.value) | .count' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}')
  reject_count=$(echo "${counts_json}" | jq -r '.results[]? | reduce .[] as $f ({}; .[$f.field]=$f.value) | select(.action=="REJECT") | .count' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}')
  if (( $(echo "${total_count} > 0" | bc -l) )); then
    reject_rate=$(awk -v r="${reject_count}" -v t="${total_count}" 'BEGIN { if (t>0) printf "%.2f", (r*100)/t; else print "0" }')
  else
    reject_rate="0"
  fi

  top_reject_bytes=$(first_number_or_zero "$(extract_field_from_result "${rejects_json}" "bytes")")
  top_talker_bytes=$(first_number_or_zero "$(extract_field_from_result "${talkers_json}" "bytes")")

  {
    echo "  Insights Log Group: ${log_group}"
    echo "  Total Samples: ${total_count}"
    echo "  Reject Count: ${reject_count}"
    echo "  Reject Rate: ${reject_rate}%"
    echo "  Top Reject Sources:"
    format_reject_entries "${rejects_json}" | sed 's/^/    - /'
    echo "  Top Talkers:"
    format_top_entries "${talkers_json}" | sed 's/^/    - /'
  } >> "${OUTPUT_FILE}"

  if (( $(echo "${reject_rate} > ${REJECT_RATE_WARN_PCT}" | bc -l) )); then
    VPCS_REJECT_ALERTS=$((VPCS_REJECT_ALERTS + 1))
    record_issue "VPC ${vpc_id} (${vpc_name}) reject rate ${reject_rate}% exceeds ${REJECT_RATE_WARN_PCT}%"
  fi

  if (( $(echo "${top_talker_bytes} > ${TOP_TALKER_BYTES_WARN}" | bc -l) )); then
    VPCS_TOPTALKER_ALERTS=$((VPCS_TOPTALKER_ALERTS + 1))
    record_issue "VPC ${vpc_id} (${vpc_name}) top talker bytes ${top_talker_bytes} exceeds ${TOP_TALKER_BYTES_WARN}"
  fi
}

analyze_vpc() {
  local vpc_json="$1"
  local vpc_id cidr name
  vpc_id=$(echo "${vpc_json}" | jq_safe '.VpcId')
  cidr=$(echo "${vpc_json}" | jq_safe '.CidrBlock')
  name=$(echo "${vpc_json}" | jq -r '.Tags[] | select(.Key=="Name") | .Value' 2>/dev/null | head -n1)
  [[ -z "${name}" || "${name}" == "null" ]] && name="(no-name)"

  TOTAL_VPCS=$((TOTAL_VPCS + 1))
  log_message INFO "Analyzing VPC ${vpc_id} (${name})"

  {
    echo "VPC: ${vpc_id} (${name})"
    echo "  CIDR: ${cidr}"
  } >> "${OUTPUT_FILE}"

  local flows_json
  flows_json=$(get_flow_logs_for_vpc "${vpc_id}")
  local flow_count
  flow_count=$(echo "${flows_json}" | jq -r '.FlowLogs | length')

  if [[ "${flow_count}" == "0" ]]; then
    VPCS_MISSING_FLOWLOGS=$((VPCS_MISSING_FLOWLOGS + 1))
    echo "  Flow Logs: NOT ENABLED" >> "${OUTPUT_FILE}"
    record_issue "VPC ${vpc_id} (${name}) has no flow logs enabled"
    echo "" >> "${OUTPUT_FILE}"
    return
  fi

  VPCS_WITH_FLOWLOGS=$((VPCS_WITH_FLOWLOGS + 1))
  echo "  Flow Logs: ${flow_count}" >> "${OUTPUT_FILE}"

  local query_log_group=""
  while read -r flow; do
    local dest_type dest status delivery log_group
    dest_type=$(echo "${flow}" | jq_safe '.LogDestinationType')
    dest=$(echo "${flow}" | jq_safe '.LogDestination // .LogGroupName')
    log_group=$(echo "${flow}" | jq_safe '.LogGroupName')
    status=$(echo "${flow}" | jq_safe '.FlowLogStatus')
    delivery=$(echo "${flow}" | jq_safe '.DeliverLogsStatus')
    echo "  - Destination: ${dest_type} -> ${dest} (FlowLogStatus=${status}, Deliver=${delivery})" >> "${OUTPUT_FILE}"
    if [[ -z "${query_log_group}" && "${dest_type}" == "cloud-watch-logs" && -n "${log_group}" ]]; then
      query_log_group="${log_group}"
    fi
  done <<< "$(echo "${flows_json}" | jq -c '.FlowLogs[]')"

  if [[ -n "${query_log_group}" ]]; then
    analyze_log_group "${vpc_id}" "${name}" "${query_log_group}"
  else
    echo "  Insights: Skipped (no CloudWatch Logs destination)" >> "${OUTPUT_FILE}"
    record_issue "VPC ${vpc_id} (${name}) has flow logs but no CloudWatch Logs destination to query"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local vpcs_json
  vpcs_json=$(list_vpcs)
  local vpc_count
  vpc_count=$(echo "${vpcs_json}" | jq -r '.Vpcs | length')
  if [[ "${vpc_count}" == "0" ]]; then
    log_message WARN "No VPCs found in region ${REGION}"
    echo "No VPCs found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total VPCs: ${vpc_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r vpc; do
    analyze_vpc "${vpc}"
  done <<< "$(echo "${vpcs_json}" | jq -c '.Vpcs[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total VPCs: ${TOTAL_VPCS}"
    echo "VPCs with Flow Logs: ${VPCS_WITH_FLOWLOGS}"
    echo "VPCs missing Flow Logs: ${VPCS_MISSING_FLOWLOGS}"
    echo "VPCs over Reject threshold: ${VPCS_REJECT_ALERTS}"
    echo "VPCs over Top Talker threshold: ${VPCS_TOPTALKER_ALERTS}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "VPC Flow Logs Analyzer detected issues:\n${joined}" "WARNING"
    send_email_alert "VPC Flow Logs Analyzer Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

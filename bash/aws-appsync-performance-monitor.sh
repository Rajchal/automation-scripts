#!/bin/bash

################################################################################
# AWS AppSync Performance Monitor
# Audits AppSync APIs: lists APIs, data sources, resolvers, schema validation,
# auth config, and pulls CloudWatch metrics (Latency, Errors, Throttles,
# DataSourceLatency). Includes env thresholds, logging, Slack/email alerts,
# and a text report with latency distribution and top errors.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/appsync-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/appsync-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds (override via env)
LATENCY_P95_WARN_MS="${LATENCY_P95_WARN_MS:-500}"     # p95 latency in ms
LATENCY_P99_WARN_MS="${LATENCY_P99_WARN_MS:-1000}"    # p99 latency in ms
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-1}"       # % errors vs requests
THROTTLE_WARN="${THROTTLE_WARN:-1}"                   # throttle count
DATASOURCE_LATENCY_WARN_MS="${DATASOURCE_LATENCY_WARN_MS:-300}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_APIS=0
APIS_WITH_ISSUES=0
TOTAL_DATASOURCES=0
DATASOURCES_WITH_ISSUES=0
TOTAL_RESOLVERS=0
RESOLVERS_HIGH_LATENCY=0

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
      "title": "AWS AppSync Alert",
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
    echo "AWS AppSync Performance Monitor"
    echo "==============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Latency p95 Warning: > ${LATENCY_P95_WARN_MS}ms"
    echo "  Latency p99 Warning: > ${LATENCY_P99_WARN_MS}ms"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  Throttles Warning: >= ${THROTTLE_WARN}"
    echo "  DataSource Latency Warning: > ${DATASOURCE_LATENCY_WARN_MS}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_apis() {
  aws_cmd appsync list-graphql-apis \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"graphqlApis":[]}'
}

get_api() {
  local api_id="$1"
  aws_cmd appsync get-graphql-api \
    --api-id "$api_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_datasources() {
  local api_id="$1"
  aws_cmd appsync list-data-sources \
    --api-id "$api_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"dataSources":[]}'
}

list_resolvers() {
  local api_id="$1"
  aws_cmd appsync list-resolvers \
    --api-id "$api_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"resolvers":[]}'
}

get_resolver() {
  local api_id="$1" type_name="$2" field_name="$3"
  aws_cmd appsync get-resolver \
    --api-id "$api_id" \
    --type-name "$type_name" \
    --field-name "$field_name" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_schema() {
  local api_id="$1"
  aws_cmd appsync get-schema-creation-status \
    --api-id "$api_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_metrics() {
  local api_id="$1" metric="$2" stat_type="${3:-Average}"
  local extra_stats=( )
  if [[ "$stat_type" == "EXTENDED" ]]; then
    extra_stats+=(--extended-statistics p95 p99)
  else
    extra_stats+=(--statistics "$stat_type")
  fi
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/AppSync \
    --metric-name "$metric" \
    --dimensions Name=GraphQLAPIId,Value="$api_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    "${extra_stats[@]}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

get_datasource_metrics() {
  local api_id="$1" datasource_name="$2" metric="$3" stat_type="${4:-Average}"
  local extra_stats=( )
  if [[ "$stat_type" == "EXTENDED" ]]; then
    extra_stats+=(--extended-statistics p95 p99)
  else
    extra_stats+=(--statistics "$stat_type")
  fi
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/AppSync \
    --metric-name "$metric" \
    --dimensions Name=GraphQLAPIId,Value="$api_id" Name=DataSourceName,Value="$datasource_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    "${extra_stats[@]}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_p() { local p="$1"; jq -r ".Datapoints[].ExtendedStatistics.p${p}" 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_datasources() {
  local api_id="$1" api_name="$2"
  local ds_json
  ds_json=$(list_datasources "$api_id")
  local ds_count
  ds_count=$(echo "${ds_json}" | jq -r '.dataSources | length')
  
  {
    echo "  Data Sources: ${ds_count}"
  } >> "${OUTPUT_FILE}"

  if [[ "${ds_count}" == "0" ]]; then
    echo "    (none configured)" >> "${OUTPUT_FILE}"
    return
  fi

  DATASOURCES_WITH_ISSUES=$((DATASOURCES_WITH_ISSUES + ds_count))

  echo "${ds_json}" | jq -c '.dataSources[]' | while read -r ds; do
    local ds_name ds_type ds_arn ds_status
    ds_name=$(echo "${ds}" | jq_safe '.name')
    ds_type=$(echo "${ds}" | jq_safe '.type')
    ds_arn=$(echo "${ds}" | jq_safe '.arn // ""')
    
    {
      echo "    - ${ds_name} (${ds_type})"
      [[ -n "${ds_arn}" ]] && echo "      ARN: ${ds_arn}"
    } >> "${OUTPUT_FILE}"

    local latency_avg latency_p95
    latency_avg=$(get_datasource_metrics "$api_id" "$ds_name" "DataSourceLatency" "Average" | calculate_avg)
    latency_p95=$(get_datasource_metrics "$api_id" "$ds_name" "DataSourceLatency" "EXTENDED" | calculate_p 95)

    {
      echo "      Latency (avg): ${latency_avg}ms"
      echo "      Latency (p95): ${latency_p95}ms"
    } >> "${OUTPUT_FILE}"

    if (( $(echo "${latency_p95} > ${DATASOURCE_LATENCY_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
      record_issue "AppSync API ${api_name} datasource ${ds_name} p95 latency ${latency_p95}ms exceeds ${DATASOURCE_LATENCY_WARN_MS}ms"
    fi
  done <<< "$(echo "${ds_json}" | jq -c '.dataSources[]')"
}

analyze_resolvers() {
  local api_id="$1" api_name="$2"
  local res_json
  res_json=$(list_resolvers "$api_id")
  local res_count
  res_count=$(echo "${res_json}" | jq -r '.resolvers | length')

  {
    echo "  Resolvers: ${res_count}"
  } >> "${OUTPUT_FILE}"

  if [[ "${res_count}" == "0" ]]; then
    echo "    (none configured)" >> "${OUTPUT_FILE}"
    return
  fi

  TOTAL_RESOLVERS=$((TOTAL_RESOLVERS + res_count))

  echo "${res_json}" | jq -c '.resolvers[]' | while read -r res; do
    local type_name field_name req_templates
    type_name=$(echo "${res}" | jq_safe '.typeName')
    field_name=$(echo "${res}" | jq_safe '.fieldName')
    req_templates=$(echo "${res}" | jq -r '.requestMappingTemplate // ""' 2>/dev/null | wc -c)

    {
      echo "    - ${type_name}.${field_name}"
    } >> "${OUTPUT_FILE}"
  done <<< "$(echo "${res_json}" | jq -c '.resolvers[]')"
}

analyze_api() {
  local api_json="$1"
  local api_id api_name auth_type status schema_status
  api_id=$(echo "${api_json}" | jq_safe '.id')
  api_name=$(echo "${api_json}" | jq_safe '.name')
  auth_type=$(echo "${api_json}" | jq_safe '.authenticationType')
  status=$(echo "${api_json}" | jq_safe '.status')

  TOTAL_APIS=$((TOTAL_APIS + 1))
  log_message INFO "Analyzing AppSync API: ${api_name} (${api_id})"

  {
    echo "API: ${api_name}"
    echo "  ID: ${api_id}"
    echo "  Auth Type: ${auth_type}"
    echo "  Status: ${status}"
  } >> "${OUTPUT_FILE}"

  # Schema status
  local schema_json
  schema_json=$(get_schema "$api_id")
  schema_status=$(echo "${schema_json}" | jq_safe '.status')
  [[ -n "${schema_status}" ]] && echo "  Schema Status: ${schema_status}" >> "${OUTPUT_FILE}"

  # CloudWatch Metrics
  local requests errors throttles
  requests=$(get_metrics "$api_id" "Requests" "Sum" | calculate_sum)
  errors=$(get_metrics "$api_id" "Errors" "Sum" | calculate_sum)
  throttles=$(get_metrics "$api_id" "Throttles" "Sum" | calculate_sum)

  local error_rate="0"
  if (( $(echo "${requests} > 0" | bc -l 2>/dev/null || echo 0) )); then
    error_rate=$(awk -v e="${errors}" -v r="${requests}" 'BEGIN { if (r>0) printf "%.2f", (e*100)/r; else print "0" }')
  fi

  {
    echo "  Requests (${LOOKBACK_HOURS}h): ${requests}"
    echo "  Errors: ${errors} (${error_rate}%)"
    echo "  Throttles: ${throttles}"
  } >> "${OUTPUT_FILE}"

  # Latency metrics
  local latency_avg latency_p95 latency_p99
  latency_avg=$(get_metrics "$api_id" "Latency" "Average" | calculate_avg)
  latency_p95=$(get_metrics "$api_id" "Latency" "EXTENDED" | calculate_p 95)
  latency_p99=$(get_metrics "$api_id" "Latency" "EXTENDED" | calculate_p 99)

  {
    echo "  Latency (avg): ${latency_avg}ms"
    echo "  Latency (p95): ${latency_p95}ms"
    echo "  Latency (p99): ${latency_p99}ms"
  } >> "${OUTPUT_FILE}"

  # Check thresholds
  if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l 2>/dev/null || echo 0) )); then
    APIS_WITH_ISSUES=$((APIS_WITH_ISSUES + 1))
    record_issue "AppSync API ${api_name} error rate ${error_rate}% exceeds ${ERROR_RATE_WARN_PCT}%"
  fi

  if (( $(echo "${throttles} >= ${THROTTLE_WARN}" | bc -l 2>/dev/null || echo 0) )); then
    APIS_WITH_ISSUES=$((APIS_WITH_ISSUES + 1))
    record_issue "AppSync API ${api_name} throttles (${throttles}) exceed threshold"
  fi

  if (( $(echo "${latency_p95} > ${LATENCY_P95_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    RESOLVERS_HIGH_LATENCY=$((RESOLVERS_HIGH_LATENCY + 1))
    record_issue "AppSync API ${api_name} p95 latency ${latency_p95}ms exceeds ${LATENCY_P95_WARN_MS}ms"
  fi

  if (( $(echo "${latency_p99} > ${LATENCY_P99_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    RESOLVERS_HIGH_LATENCY=$((RESOLVERS_HIGH_LATENCY + 1))
    record_issue "AppSync API ${api_name} p99 latency ${latency_p99}ms exceeds ${LATENCY_P99_WARN_MS}ms"
  fi

  # Analyze data sources
  analyze_datasources "$api_id" "$api_name"

  # Analyze resolvers
  analyze_resolvers "$api_id" "$api_name"

  echo "" >> "${OUTPUT_FILE}"
}

main() {
  write_header
  local apis_json
  apis_json=$(list_apis)
  local api_count
  api_count=$(echo "${apis_json}" | jq -r '.graphqlApis | length')
  
  if [[ "${api_count}" == "0" ]]; then
    log_message WARN "No AppSync APIs found in region ${REGION}"
    echo "No AppSync APIs found." >> "${OUTPUT_FILE}"
    exit 0
  fi

  echo "Total APIs: ${api_count}" >> "${OUTPUT_FILE}"
  echo "" >> "${OUTPUT_FILE}"

  while read -r api; do
    analyze_api "${api}"
  done <<< "$(echo "${apis_json}" | jq -c '.graphqlApis[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total APIs: ${TOTAL_APIS}"
    echo "APIs with Issues: ${APIS_WITH_ISSUES}"
    echo "Total Resolvers: ${TOTAL_RESOLVERS}"
    echo "Resolvers with High Latency: ${RESOLVERS_HIGH_LATENCY}"
    echo "Total Data Sources: ${TOTAL_DATASOURCES}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "AppSync Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "AppSync Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

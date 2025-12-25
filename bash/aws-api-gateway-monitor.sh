#!/bin/bash

################################################################################
# AWS API Gateway Monitor
# Audits API Gateway (REST, HTTP, WebSocket): lists APIs and stages, checks
# logging/tracing, evaluates integrations, and pulls CloudWatch metrics
# (AWS/ApiGateway 4XX/5XX errors, latency, throttles, request count).
# Includes env thresholds, logging, Slack/email alerts, and text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
API_TYPE="${API_TYPE:-ALL}"                 # REST | HTTP | WEBSOCKET | ALL
OUTPUT_FILE="/tmp/api-gateway-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/api-gateway-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds (override via env)
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-5}"     # % of 4XX+5XX vs total requests
LATENCY_WARN_MS="${LATENCY_WARN_MS:-1000}"           # avg latency in ms
THROTTLE_WARN="${THROTTLE_WARN:-10}"                 # throttled requests count
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
TOTAL_STAGES=0
APIS_WITHOUT_LOGGING=0
APIS_HIGH_ERROR_RATE=0
APIS_HIGH_LATENCY=0
APIS_THROTTLED=0
INTEGRATIONS_FAILED=0
TOTAL_INTEGRATIONS=0

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
      "title": "AWS API Gateway Alert",
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
    echo "AWS API Gateway Monitor"
    echo "======================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "API Types: ${API_TYPE}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo "  Latency Warning: > ${LATENCY_WARN_MS}ms"
    echo "  Throttle Warning: > ${THROTTLE_WARN} requests"
    echo ""
  } > "${OUTPUT_FILE}"
}

# API Gateway API wrappers
list_rest_apis() {
  aws apigateway get-rest-apis \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"items":[]}'
}

list_http_apis() {
  aws apigatewayv2 get-apis \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Items":[]}'
}

get_rest_api_detail() {
  local api_id="$1"
  aws apigateway get-rest-api \
    --rest-api-id "$api_id" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{}'
}

get_http_api_detail() {
  local api_id="$1"
  aws apigatewayv2 get-api \
    --api-id "$api_id" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{}'
}

get_stages() {
  local api_id="$1" api_type="$2"
  if [[ "$api_type" == "REST" ]]; then
    aws apigateway get-stages \
      --rest-api-id "$api_id" \
      --region "$REGION" \
      --output json 2>/dev/null || echo '{"item":[]}'
  else
    aws apigatewayv2 get-stages \
      --api-id "$api_id" \
      --region "$REGION" \
      --output json 2>/dev/null || echo '{"Items":[]}'
  fi
}

get_stage_detail() {
  local api_id="$1" stage_name="$2" api_type="$3"
  if [[ "$api_type" == "REST" ]]; then
    aws apigateway get-stage \
      --rest-api-id "$api_id" \
      --stage-name "$stage_name" \
      --region "$REGION" \
      --output json 2>/dev/null || echo '{}'
  else
    aws apigatewayv2 get-stage \
      --api-id "$api_id" \
      --stage-name "$stage_name" \
      --region "$REGION" \
      --output json 2>/dev/null || echo '{}'
  fi
}

get_resources() {
  local api_id="$1"
  aws apigateway get-resources \
    --rest-api-id "$api_id" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"items":[]}'
}

get_integrations() {
  local api_id="$1"
  local resources
  resources=$(get_resources "$api_id")
  local items
  items=$(echo "$resources" | jq -c '.items[]?' 2>/dev/null)
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue
    local resource_id
    resource_id=$(echo "$item" | jq_safe '.id')
    [[ -z "$resource_id" ]] && continue
    aws apigateway get-integration \
      --rest-api-id "$api_id" \
      --resource-id "$resource_id" \
      --http-method GET \
      --region "$REGION" \
      --output json 2>/dev/null || true
  done <<< "$items"
}

list_integrations_v2() {
  local api_id="$1"
  aws apigatewayv2 get-integrations \
    --api-id "$api_id" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Items":[]}'
}

# CloudWatch metrics
get_api_metrics() {
  local api_name="$1" stage_name="$2" metric_name="$3"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ApiGateway \
    --metric-name "$metric_name" \
    --dimensions Name=ApiName,Value="$api_name" Name=Stage,Value="$stage_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics Sum,Average \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

write_api_header() {
  local api_name="$1" api_type="$2"
  {
    echo "API: ${api_name} (${api_type})"
    echo "  Type: ${api_type}"
  } >> "${OUTPUT_FILE}"
}

monitor_rest_api() {
  local api_id="$1" api_name="$2"
  log_message INFO "Analyzing REST API: ${api_name}"
  write_api_header "$api_name" "REST"
  
  local api_detail
  api_detail=$(get_rest_api_detail "$api_id")
  local description enabled_cloudtrail
  description=$(echo "$api_detail" | jq_safe '.description // ""')
  enabled_cloudtrail=$(echo "$api_detail" | jq_safe '.cloudwatchRoleArn // "none"')
  
  [[ -n "$description" ]] && {
    echo "  Description: ${description}" >> "${OUTPUT_FILE}"
  }
  
  if [[ "$enabled_cloudtrail" == "none" ]]; then
    ((APIS_WITHOUT_LOGGING++))
    {
      printf "  %b⚠️  No CloudWatch role configured%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  else
    {
      echo "  CloudWatch Role: configured"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Stages
  local stages_json
  stages_json=$(get_stages "$api_id" "REST")
  local stages_count
  stages_count=$(echo "$stages_json" | jq '.item | length' 2>/dev/null || echo "0")
  TOTAL_STAGES=$((TOTAL_STAGES + stages_count))
  
  {
    echo "  Stages: ${stages_count}"
  } >> "${OUTPUT_FILE}"
  
  local stage_items
  stage_items=$(echo "$stages_json" | jq -c '.item[]?' 2>/dev/null)
  while IFS= read -r stage; do
    [[ -z "$stage" ]] && continue
    local stage_name logging_level metrics_enabled
    stage_name=$(echo "$stage" | jq_safe '.stageName')
    logging_level=$(echo "$stage" | jq_safe '.methodSettings."*/*".loggingLevel // "OFF"')
    metrics_enabled=$(echo "$stage" | jq_safe '.methodSettings."*/*".metricsEnabled // false')
    
    {
      echo "    - ${stage_name}"
      echo "      Logging: ${logging_level}"
      echo "      Metrics: ${metrics_enabled}"
    } >> "${OUTPUT_FILE}"
    
    # Metrics for this stage
    analyze_stage_metrics "$api_name" "$stage_name"
  done <<< "$stage_items"
  
  # Integrations (REST)
  analyze_rest_integrations "$api_id"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_rest_integrations() {
  local api_id="$1"
  local integrations
  integrations=$(get_integrations "$api_id" 2>/dev/null || echo '[]')
  local count
  count=$(echo "$integrations" | jq -r 'keys | length' 2>/dev/null || echo "0")
  TOTAL_INTEGRATIONS=$((TOTAL_INTEGRATIONS + count))
  
  {
    echo "  Integrations: ${count}"
  } >> "${OUTPUT_FILE}"
}

monitor_http_api() {
  local api_id="$1" api_name="$2"
  log_message INFO "Analyzing HTTP API: ${api_name}"
  write_api_header "$api_name" "HTTP"
  
  local api_detail
  api_detail=$(get_http_api_detail "$api_id")
  local protocol_type cors
  protocol_type=$(echo "$api_detail" | jq_safe '.ProtocolType // "HTTP"')
  cors=$(echo "$api_detail" | jq_safe '.CorsPolicy // ""')
  
  {
    echo "  Protocol: ${protocol_type}"
    [[ -n "$cors" && "$cors" != "null" ]] && echo "  CORS: enabled"
  } >> "${OUTPUT_FILE}"
  
  # Stages
  local stages_json
  stages_json=$(get_stages "$api_id" "HTTP")
  local stages_count
  stages_count=$(echo "$stages_json" | jq '.Items | length' 2>/dev/null || echo "0")
  TOTAL_STAGES=$((TOTAL_STAGES + stages_count))
  
  {
    echo "  Stages: ${stages_count}"
  } >> "${OUTPUT_FILE}"
  
  local stage_items
  stage_items=$(echo "$stages_json" | jq -c '.Items[]?' 2>/dev/null)
  while IFS= read -r stage; do
    [[ -z "$stage" ]] && continue
    local stage_name logging_enabled throttle_settings
    stage_name=$(echo "$stage" | jq_safe '.StageName')
    logging_enabled=$(echo "$stage" | jq_safe '.AccessLogSettings // ""')
    throttle_settings=$(echo "$stage" | jq_safe '.ThrottleSettings // ""')
    
    {
      echo "    - ${stage_name}"
      [[ -n "$logging_enabled" && "$logging_enabled" != "null" ]] && echo "      Logging: enabled" || echo "      Logging: disabled"
      [[ -n "$throttle_settings" && "$throttle_settings" != "null" ]] && echo "      Throttling: configured"
    } >> "${OUTPUT_FILE}"
    
    # Metrics for this stage
    analyze_stage_metrics "$api_name" "$stage_name"
  done <<< "$stage_items"
  
  # Integrations (HTTP)
  analyze_http_integrations "$api_id"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_http_integrations() {
  local api_id="$1"
  local integrations
  integrations=$(list_integrations_v2 "$api_id")
  local count
  count=$(echo "$integrations" | jq '.Items | length' 2>/dev/null || echo "0")
  TOTAL_INTEGRATIONS=$((TOTAL_INTEGRATIONS + count))
  
  {
    echo "  Integrations: ${count}"
  } >> "${OUTPUT_FILE}"
}

analyze_stage_metrics() {
  local api_name="$1" stage_name="$2"
  {
    echo "      Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  local count_json error_4xx_json error_5xx_json latency_json throttle_json
  count_json=$(get_api_metrics "$api_name" "$stage_name" "Count")
  error_4xx_json=$(get_api_metrics "$api_name" "$stage_name" "4XXError")
  error_5xx_json=$(get_api_metrics "$api_name" "$stage_name" "5XXError")
  latency_json=$(get_api_metrics "$api_name" "$stage_name" "Latency")
  throttle_json=$(get_api_metrics "$api_name" "$stage_name" "ThrottledRequests")
  
  local count_sum error_4xx_sum error_5xx_sum latency_avg throttle_sum
  count_sum=$(echo "$count_json" | calculate_sum)
  error_4xx_sum=$(echo "$error_4xx_json" | calculate_sum)
  error_5xx_sum=$(echo "$error_5xx_json" | calculate_sum)
  latency_avg=$(echo "$latency_json" | calculate_avg)
  throttle_sum=$(echo "$throttle_json" | calculate_sum)
  
  {
    echo "        Requests: ${count_sum}"
    echo "        Errors 4XX: ${error_4xx_sum}"
    echo "        Errors 5XX: ${error_5xx_sum}"
    echo "        Latency Avg: ${latency_avg}ms"
    echo "        Throttled: ${throttle_sum}"
  } >> "${OUTPUT_FILE}"
  
  # Check thresholds
  local error_rate="0"
  if [[ ${count_sum} -gt 0 ]]; then
    local error_total
    error_total=$((error_4xx_sum + error_5xx_sum))
    error_rate=$(echo "scale=2; ${error_total} * 100 / ${count_sum}" | bc -l 2>/dev/null || echo "0")
  fi
  
  if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l) )); then
    ((APIS_HIGH_ERROR_RATE++))
    {
      printf "        %b⚠️  High error rate: %.2f%%%b\n" "${RED}" "$error_rate" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  if (( $(echo "${latency_avg} > ${LATENCY_WARN_MS}" | bc -l) )); then
    ((APIS_HIGH_LATENCY++))
    {
      printf "        %b⚠️  High latency%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  if (( $(echo "${throttle_sum} > ${THROTTLE_WARN}" | bc -l) )); then
    ((APIS_THROTTLED++))
    {
      printf "        %b⚠️  Throttling detected%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
}

summary_section() {
  {
    echo ""
    echo "=== API GATEWAY SUMMARY ==="
    echo ""
    printf "Total APIs: %d\n" "${TOTAL_APIS}"
    printf "Total Stages: %d\n" "${TOTAL_STAGES}"
    printf "Total Integrations: %d\n" "${TOTAL_INTEGRATIONS}"
    echo ""
    printf "APIs Without Logging: %d\n" "${APIS_WITHOUT_LOGGING}"
    printf "APIs High Error Rate: %d\n" "${APIS_HIGH_ERROR_RATE}"
    printf "APIs High Latency: %d\n" "${APIS_HIGH_LATENCY}"
    printf "APIs Throttled: %d\n" "${APIS_THROTTLED}"
    echo ""
    if [[ ${APIS_HIGH_ERROR_RATE} -gt 0 ]] || [[ ${APIS_THROTTLED} -gt 0 ]]; then
      printf "%b[CRITICAL] API errors or throttling detected%b\n" "${RED}" "${NC}"
    elif [[ ${APIS_HIGH_LATENCY} -gt 0 ]] || [[ ${APIS_WITHOUT_LOGGING} -gt 0 ]]; then
      printf "%b[WARNING] High latency or logging issues%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] APIs appear healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations_section() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${APIS_WITHOUT_LOGGING} -gt 0 ]]; then
      echo "Enable CloudWatch Logging:"
      echo "  • Assign CloudWatch IAM role to API Gateway"
      echo "  • Enable logging for all */\* methods"
      echo "  • Set format to include request/response bodies (caution: PII)"
      echo "  • Use ERROR or INFO log levels"
      echo "  • Retain logs 7-30 days"
      echo ""
    fi
    if [[ ${APIS_HIGH_ERROR_RATE} -gt 0 ]]; then
      echo "Troubleshoot High Error Rates:"
      echo "  • Check backend integration status"
      echo "  • Review API logs in CloudWatch"
      echo "  • Validate authorization (API keys, OAuth, mTLS)"
      echo "  • Inspect X-Ray traces for failures"
      echo "  • Check integration timeouts and response codes"
      echo ""
    fi
    if [[ ${APIS_HIGH_LATENCY} -gt 0 ]]; then
      echo "Reduce API Latency:"
      echo "  • Enable API Gateway caching"
      echo "  • Optimize backend integrations"
      echo "  • Use connection pooling"
      echo "  • Enable Lambda reserved concurrency"
      echo "  • Review authorization performance"
      echo "  • Check payload size (request/response)"
      echo ""
    fi
    if [[ ${APIS_THROTTLED} -gt 0 ]]; then
      echo "Handle Throttling:"
      echo "  • Increase stage throttle limits (default 10k reqs/s)"
      echo "  • Implement client-side exponential backoff"
      echo "  • Use queue service (SQS) for async workloads"
      echo "  • Add request rate-based WAF rules"
      echo "  • Review usage plans and API keys"
      echo ""
    fi
    echo "Security Best Practices:"
    echo "  • Enable API Gateway logging and WAF"
    echo "  • Use IAM, Lambda authorizers, or Cognito"
    echo "  • Enforce TLS 1.2+"
    echo "  • Implement API key rotation"
    echo "  • Use VPC endpoints for private APIs"
    echo "  • Enable X-Ray tracing for debugging"
    echo ""
    echo "Observability & Monitoring:"
    echo "  • CloudWatch alarms on 4XX/5XX and latency"
    echo "  • X-Ray for distributed tracing"
    echo "  • API Gateway execution logs"
    echo "  • Access logs in S3"
    echo "  • SNS/Slack notifications for anomalies"
    echo ""
    echo "Cost Optimization:"
    echo "  • Monitor API usage and cache hits"
    echo "  • Consolidate redundant APIs"
    echo "  • Use HTTP APIs (lower cost than REST)"
    echo "  • Leverage CloudFront for static content"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== API Gateway Monitor Started ==="
  write_header
  
  # REST APIs
  if [[ "$API_TYPE" == "REST" ]] || [[ "$API_TYPE" == "ALL" ]]; then
    local rest_apis
    rest_apis=$(list_rest_apis)
    local rest_count
    rest_count=$(echo "$rest_apis" | jq '.items | length' 2>/dev/null || echo "0")
    TOTAL_APIS=$((TOTAL_APIS + rest_count))
    
    if [[ ${rest_count} -gt 0 ]]; then
      {
        echo "=== REST APIs (${rest_count}) ==="
        echo ""
      } >> "${OUTPUT_FILE}"
      
      local rest_items
      rest_items=$(echo "$rest_apis" | jq -c '.items[]?' 2>/dev/null)
      while IFS= read -r api; do
        [[ -z "$api" ]] && continue
        local api_id api_name
        api_id=$(echo "$api" | jq_safe '.id')
        api_name=$(echo "$api" | jq_safe '.name')
        monitor_rest_api "$api_id" "$api_name"
      done <<< "$rest_items"
    fi
  fi
  
  # HTTP APIs
  if [[ "$API_TYPE" == "HTTP" ]] || [[ "$API_TYPE" == "ALL" ]]; then
    local http_apis
    http_apis=$(list_http_apis)
    local http_count
    http_count=$(echo "$http_apis" | jq '.Items | length' 2>/dev/null || echo "0")
    TOTAL_APIS=$((TOTAL_APIS + http_count))
    
    if [[ ${http_count} -gt 0 ]]; then
      {
        echo "=== HTTP APIs (${http_count}) ==="
        echo ""
      } >> "${OUTPUT_FILE}"
      
      local http_items
      http_items=$(echo "$http_apis" | jq -c '.Items[]?' 2>/dev/null)
      while IFS= read -r api; do
        [[ -z "$api" ]] && continue
        local api_id api_name
        api_id=$(echo "$api" | jq_safe '.ApiId')
        api_name=$(echo "$api" | jq_safe '.Name')
        monitor_http_api "$api_id" "$api_name"
      done <<< "$http_items"
    fi
  fi
  
  summary_section
  recommendations_section
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS API Gateway Documentation: https://docs.aws.amazon.com/apigateway/latest/developerguide/"
  } >> "${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
  log_message INFO "=== API Gateway Monitor Completed ==="
  
  # Alerts
  if [[ ${APIS_HIGH_ERROR_RATE} -gt 0 ]] || [[ ${APIS_THROTTLED} -gt 0 ]]; then
    send_slack_alert "🚨 API Gateway errors or throttling: errors=${APIS_HIGH_ERROR_RATE}, throttled=${APIS_THROTTLED}" "CRITICAL"
    send_email_alert "API Gateway Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${APIS_HIGH_LATENCY} -gt 0 ]] || [[ ${APIS_WITHOUT_LOGGING} -gt 0 ]]; then
    send_slack_alert "⚠️ API Gateway issues: latency=${APIS_HIGH_LATENCY}, no_logging=${APIS_WITHOUT_LOGGING}" "WARNING"
  fi
}

main "$@"

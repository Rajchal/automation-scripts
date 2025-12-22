#!/bin/bash

################################################################################
# AWS API Gateway Performance Tracker
# Analyzes API Gateway REST/HTTP APIs, tracks latency, error rates, cache hit
# ratios, throttling, request patterns, and provides optimization guidance.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/apigateway-performance-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/apigateway-performance.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
LATENCY_WARN_MS="${LATENCY_WARN_MS:-1000}"          # ms
ERROR_RATE_WARN="${ERROR_RATE_WARN_PCT:-5}"         # % 4XX+5XX errors
CACHE_HIT_RATIO_MIN="${CACHE_HIT_RATIO_MIN:-70}"    # %
THROTTLE_WARN="${THROTTLE_WARN:-100}"               # count
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_REST_APIS=0
TOTAL_HTTP_APIS=0
HIGH_LATENCY_APIS=0
HIGH_ERROR_APIS=0
THROTTLED_APIS=0

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
      "title": "API Gateway Performance Alert",
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
    echo "AWS API Gateway Performance Tracker"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Latency Warning: ${LATENCY_WARN_MS}ms"
    echo "  Error Rate Warning: ${ERROR_RATE_WARN_PCT}%"
    echo "  Cache Hit Ratio Minimum: ${CACHE_HIT_RATIO_MIN}%"
    echo "  Throttle Warning: ${THROTTLE_WARN} requests"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_rest_apis() {
  aws apigateway get-rest-apis \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"items":[]}'
}

list_http_apis() {
  aws apigatewayv2 get-apis \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Items":[]}'
}

get_rest_api() {
  local api_id="$1"
  aws apigateway get-rest-api \
    --rest-api-id "${api_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_stages() {
  local api_id="$1"
  aws apigateway get-stages \
    --rest-api-id "${api_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"item":[]}'
}

list_http_stages() {
  local api_id="$1"
  aws apigatewayv2 get-stages \
    --api-id "${api_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Items":[]}'
}

get_apigw_metrics() {
  local api_name="$1"
  local stage="$2"
  local metric_name="$3"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ApiGateway \
    --metric-name "${metric_name}" \
    --dimensions Name=ApiName,Value="${api_name}" Name=Stage,Value="${stage}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() {
  jq -r '.Datapoints[].Sum' 2>/dev/null | \
    awk '{s+=$1} END {printf "%.0f", s}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

calculate_max() {
  jq -r '.Datapoints[].Maximum' 2>/dev/null | \
    awk 'BEGIN{max=0} {if($1>max) max=$1} END{printf "%.2f", max}'
}

monitor_rest_apis() {
  log_message INFO "Monitoring REST APIs"
  
  {
    echo "=== REST API GATEWAY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local apis_json
  apis_json=$(list_rest_apis)
  
  local api_count
  api_count=$(echo "${apis_json}" | jq '.items | length' 2>/dev/null || echo "0")
  
  TOTAL_REST_APIS=${api_count}
  
  if [[ ${api_count} -eq 0 ]]; then
    {
      echo "No REST APIs found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total REST APIs: ${api_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local apis
  apis=$(echo "${apis_json}" | jq -c '.items[]' 2>/dev/null)
  
  while IFS= read -r api; do
    [[ -z "${api}" ]] && continue
    
    local api_id api_name created_date endpoint_config
    api_id=$(echo "${api}" | jq_safe '.id')
    api_name=$(echo "${api}" | jq_safe '.name')
    created_date=$(echo "${api}" | jq_safe '.createdDate')
    endpoint_config=$(echo "${api}" | jq_safe '.endpointConfiguration.types[0]')
    
    log_message INFO "Analyzing REST API: ${api_name}"
    
    {
      echo "REST API: ${api_name}"
      echo "ID: ${api_id}"
      echo "Endpoint Type: ${endpoint_config}"
      echo "Created: ${created_date}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze stages
    analyze_rest_stages "${api_id}" "${api_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${apis}"
}

analyze_rest_stages() {
  local api_id="$1"
  local api_name="$2"
  
  {
    echo "Stages:"
  } >> "${OUTPUT_FILE}"
  
  local stages_json
  stages_json=$(list_stages "${api_id}")
  
  local stage_count
  stage_count=$(echo "${stages_json}" | jq '.item | length' 2>/dev/null || echo "0")
  
  if [[ ${stage_count} -eq 0 ]]; then
    {
      echo "  No stages deployed"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local stages
  stages=$(echo "${stages_json}" | jq -c '.item[]' 2>/dev/null)
  
  while IFS= read -r stage; do
    [[ -z "${stage}" ]] && continue
    
    local stage_name deployment_id cache_enabled throttle_enabled
    stage_name=$(echo "${stage}" | jq_safe '.stageName')
    deployment_id=$(echo "${stage}" | jq_safe '.deploymentId')
    cache_enabled=$(echo "${stage}" | jq_safe '.cacheClusterEnabled // false')
    throttle_enabled=$(echo "${stage}" | jq_safe '.throttlingBurstLimit != null')
    
    {
      echo "  Stage: ${stage_name}"
      echo "    Deployment: ${deployment_id}"
      echo "    Cache Enabled: ${cache_enabled}"
    } >> "${OUTPUT_FILE}"
    
    # Get throttling settings
    local burst_limit rate_limit
    burst_limit=$(echo "${stage}" | jq_safe '.throttlingBurstLimit // "N/A"')
    rate_limit=$(echo "${stage}" | jq_safe '.throttlingRateLimit // "N/A"')
    
    if [[ "${burst_limit}" != "N/A" ]]; then
      {
        echo "    Throttle Burst Limit: ${burst_limit}"
        echo "    Throttle Rate Limit: ${rate_limit}/sec"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze performance metrics
    analyze_stage_performance "${api_name}" "${stage_name}"
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stages}"
}

analyze_stage_performance() {
  local api_name="$1"
  local stage_name="$2"
  
  {
    echo "    Performance Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get request count
  local count_json
  count_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "Count")
  
  local request_count
  request_count=$(echo "${count_json}" | calculate_sum)
  
  {
    echo "      Total Requests: ${request_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${request_count} -eq 0 ]]; then
    {
      echo "      No traffic in analysis window"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Get latency metrics
  local latency_json integration_latency_json
  latency_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "Latency")
  integration_latency_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "IntegrationLatency")
  
  local avg_latency max_latency avg_integration_latency
  avg_latency=$(echo "${latency_json}" | calculate_avg)
  max_latency=$(echo "${latency_json}" | calculate_max)
  avg_integration_latency=$(echo "${integration_latency_json}" | calculate_avg)
  
  {
    echo "      Average Latency: ${avg_latency}ms"
    echo "      Max Latency: ${max_latency}ms"
    echo "      Average Integration Latency: ${avg_integration_latency}ms"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_latency} > ${LATENCY_WARN_MS}" | bc -l) )); then
    ((HIGH_LATENCY_APIS++))
    {
      printf "      %b⚠️  High latency detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "API ${api_name}/${stage_name} has high latency: ${avg_latency}ms"
  else
    {
      printf "      %b✓ Latency within acceptable range%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Get error metrics
  local error_4xx_json error_5xx_json
  error_4xx_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "4XXError")
  error_5xx_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "5XXError")
  
  local error_4xx_count error_5xx_count
  error_4xx_count=$(echo "${error_4xx_json}" | calculate_sum)
  error_5xx_count=$(echo "${error_5xx_json}" | calculate_sum)
  
  local total_errors
  total_errors=$((error_4xx_count + error_5xx_count))
  
  {
    echo "      4XX Errors: ${error_4xx_count}"
    echo "      5XX Errors: ${error_5xx_count}"
  } >> "${OUTPUT_FILE}"
  
  # Calculate error rate
  if [[ ${request_count} -gt 0 ]]; then
    local error_rate
    error_rate=$(echo "scale=2; ${total_errors} * 100 / ${request_count}" | bc -l)
    
    {
      echo "      Error Rate: ${error_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l) )); then
      ((HIGH_ERROR_APIS++))
      {
        printf "      %b⚠️  High error rate detected%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "API ${api_name}/${stage_name} has high error rate: ${error_rate}%"
    else
      {
        printf "      %b✓ Error rate within acceptable range%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  # Get cache metrics
  local cache_hit_json cache_miss_json
  cache_hit_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "CacheHitCount")
  cache_miss_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "CacheMissCount")
  
  local cache_hit_count cache_miss_count
  cache_hit_count=$(echo "${cache_hit_json}" | calculate_sum)
  cache_miss_count=$(echo "${cache_miss_json}" | calculate_sum)
  
  if [[ ${cache_hit_count} -gt 0 ]] || [[ ${cache_miss_count} -gt 0 ]]; then
    local total_cache_requests
    total_cache_requests=$((cache_hit_count + cache_miss_count))
    
    local cache_hit_ratio
    cache_hit_ratio=$(echo "scale=2; ${cache_hit_count} * 100 / ${total_cache_requests}" | bc -l)
    
    {
      echo "      Cache Hit Count: ${cache_hit_count}"
      echo "      Cache Miss Count: ${cache_miss_count}"
      echo "      Cache Hit Ratio: ${cache_hit_ratio}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${cache_hit_ratio} < ${CACHE_HIT_RATIO_MIN}" | bc -l) )); then
      {
        printf "      %b⚠️  Low cache hit ratio%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "API ${api_name}/${stage_name} has low cache hit ratio: ${cache_hit_ratio}%"
    else
      {
        printf "      %b✓ Cache performing well%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  # Get throttling
  local throttle_json
  throttle_json=$(get_apigw_metrics "${api_name}" "${stage_name}" "Count")
  
  local throttle_count
  throttle_count=$(echo "${throttle_json}" | jq '[.Datapoints[].Sum // 0] | add' 2>/dev/null || echo "0")
  
  if [[ ${throttle_count} -gt ${THROTTLE_WARN} ]]; then
    ((THROTTLED_APIS++))
    {
      echo "      Throttled Requests: ${throttle_count}"
      printf "      %b⚠️  Throttling detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "API ${api_name}/${stage_name} has throttled requests: ${throttle_count}"
  fi
}

monitor_http_apis() {
  log_message INFO "Monitoring HTTP APIs"
  
  {
    echo "=== HTTP API GATEWAY (v2) ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local apis_json
  apis_json=$(list_http_apis)
  
  local api_count
  api_count=$(echo "${apis_json}" | jq '.Items | length' 2>/dev/null || echo "0")
  
  TOTAL_HTTP_APIS=${api_count}
  
  if [[ ${api_count} -eq 0 ]]; then
    {
      echo "No HTTP APIs found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total HTTP APIs: ${api_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local apis
  apis=$(echo "${apis_json}" | jq -c '.Items[]' 2>/dev/null)
  
  while IFS= read -r api; do
    [[ -z "${api}" ]] && continue
    
    local api_id api_name protocol_type created_date
    api_id=$(echo "${api}" | jq_safe '.ApiId')
    api_name=$(echo "${api}" | jq_safe '.Name')
    protocol_type=$(echo "${api}" | jq_safe '.ProtocolType')
    created_date=$(echo "${api}" | jq_safe '.CreatedDate')
    
    log_message INFO "Analyzing HTTP API: ${api_name}"
    
    {
      echo "HTTP API: ${api_name}"
      echo "ID: ${api_id}"
      echo "Protocol: ${protocol_type}"
      echo "Created: ${created_date}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze stages
    analyze_http_stages "${api_id}" "${api_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${apis}"
}

analyze_http_stages() {
  local api_id="$1"
  local api_name="$2"
  
  {
    echo "Stages:"
  } >> "${OUTPUT_FILE}"
  
  local stages_json
  stages_json=$(list_http_stages "${api_id}")
  
  local stage_count
  stage_count=$(echo "${stages_json}" | jq '.Items | length' 2>/dev/null || echo "0")
  
  if [[ ${stage_count} -eq 0 ]]; then
    {
      echo "  No stages deployed"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local stages
  stages=$(echo "${stages_json}" | jq -c '.Items[]' 2>/dev/null)
  
  while IFS= read -r stage; do
    [[ -z "${stage}" ]] && continue
    
    local stage_name auto_deploy
    stage_name=$(echo "${stage}" | jq_safe '.StageName')
    auto_deploy=$(echo "${stage}" | jq_safe '.AutoDeploy // false')
    
    {
      echo "  Stage: ${stage_name}"
      echo "    Auto Deploy: ${auto_deploy}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # HTTP API metrics work similarly to REST API
    analyze_stage_performance "${api_name}" "${stage_name}"
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${stages}"
}

generate_summary() {
  {
    echo ""
    echo "=== API GATEWAY SUMMARY ==="
    echo ""
    printf "Total REST APIs: %d\n" "${TOTAL_REST_APIS}"
    printf "Total HTTP APIs: %d\n" "${TOTAL_HTTP_APIS}"
    echo ""
    echo "Performance Issues:"
    printf "  High Latency APIs: %d\n" "${HIGH_LATENCY_APIS}"
    printf "  High Error Rate APIs: %d\n" "${HIGH_ERROR_APIS}"
    printf "  Throttled APIs: %d\n" "${THROTTLED_APIS}"
    echo ""
    
    if [[ ${HIGH_LATENCY_APIS} -gt 0 ]] || [[ ${HIGH_ERROR_APIS} -gt 0 ]] || [[ ${THROTTLED_APIS} -gt 0 ]]; then
      printf "%b[WARNING] Performance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All APIs performing within acceptable ranges%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${HIGH_LATENCY_APIS} -gt 0 ]]; then
      echo "Latency Optimization:"
      echo "  • Enable API Gateway caching (0.5GB to 237GB)"
      echo "  • Implement CloudFront distribution for static responses"
      echo "  • Optimize backend integration (Lambda, HTTP, VPC Link)"
      echo "  • Use Lambda Provisioned Concurrency for predictable latency"
      echo "  • Enable compression for large payloads"
      echo "  • Consider HTTP API over REST API (60% cheaper, lower latency)"
      echo "  • Implement request/response transformation efficiently"
      echo "  • Use VPC endpoints for private integrations"
      echo ""
    fi
    
    if [[ ${HIGH_ERROR_APIS} -gt 0 ]]; then
      echo "Error Rate Reduction:"
      echo "  • Review 4XX errors (client-side validation, auth issues)"
      echo "  • Investigate 5XX errors (backend failures, timeouts)"
      echo "  • Implement proper error handling in Lambda functions"
      echo "  • Set appropriate timeout values (29s max for API Gateway)"
      echo "  • Enable CloudWatch Logs for detailed error analysis"
      echo "  • Implement retry logic with exponential backoff"
      echo "  • Use API Gateway request validation"
      echo ""
    fi
    
    if [[ ${THROTTLED_APIS} -gt 0 ]]; then
      echo "Throttling Management:"
      echo "  • Review and adjust throttling limits per stage/method"
      echo "  • Default: 10,000 requests/sec, 5,000 burst"
      echo "  • Request limit increases via AWS Support"
      echo "  • Implement usage plans for API keys"
      echo "  • Use SQS for asynchronous request handling"
      echo "  • Implement client-side rate limiting"
      echo "  • Consider AWS WAF rate-based rules"
      echo ""
    fi
    
    echo "Caching Best Practices:"
    echo "  • Enable caching for GET methods only"
    echo "  • Set appropriate TTL (60-3600 seconds typical)"
    echo "  • Use cache keys wisely (query params, headers)"
    echo "  • Implement cache invalidation strategies"
    echo "  • Monitor cache hit ratio (target >70%)"
    echo "  • Consider CloudFront for global caching"
    echo "  • Use conditional requests (ETag, If-Modified-Since)"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • HTTP API: $1/million requests (vs $3.50 for REST API)"
    echo "  • Cache pricing: $0.02/hour per GB"
    echo "  • Use usage plans to monetize APIs"
    echo "  • Implement request throttling to control costs"
    echo "  • Review CloudWatch Logs retention (default: never expire)"
    echo "  • Disable X-Ray tracing in non-production if not needed"
    echo "  • Clean up unused APIs and stages"
    echo ""
    
    echo "Security Best Practices:"
    echo "  • Enable AWS WAF for API protection"
    echo "  • Use Lambda authorizers or Cognito for authentication"
    echo "  • Implement API keys for partner access"
    echo "  • Enable CloudTrail logging for audit trail"
    echo "  • Use resource policies for IP whitelisting"
    echo "  • Implement CORS properly"
    echo "  • Use private APIs with VPC endpoints when possible"
    echo "  • Enable mutual TLS authentication"
    echo ""
    
    echo "Monitoring & Observability:"
    echo "  • Enable CloudWatch detailed metrics"
    echo "  • Set up CloudWatch alarms for 4XX, 5XX, latency"
    echo "  • Enable access logging to S3/CloudWatch Logs"
    echo "  • Use AWS X-Ray for distributed tracing"
    echo "  • Implement custom metrics via Lambda"
    echo "  • Create CloudWatch dashboards for key metrics"
    echo "  • Monitor API usage per client (API keys)"
    echo ""
    
    echo "REST API vs HTTP API Decision:"
    echo "  Choose REST API for:"
    echo "    - API key management"
    echo "    - Request/response transformation"
    echo "    - Usage plans and throttling per API key"
    echo "    - AWS WAF integration"
    echo "  Choose HTTP API for:"
    echo "    - Lower cost (71% cheaper)"
    echo "    - Better performance (lower latency)"
    echo "    - Native OIDC/OAuth 2.0 support"
    echo "    - Simpler configuration"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== API Gateway Performance Tracker Started ==="
  
  write_header
  monitor_rest_apis
  monitor_http_apis
  generate_summary
  optimization_recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS API Gateway Documentation:"
    echo "  https://docs.aws.amazon.com/apigateway/"
    echo ""
    echo "Enable CloudWatch Logs:"
    echo "  aws apigateway update-stage --rest-api-id <id> --stage-name <stage> \\"
    echo "    --patch-operations op=replace,path=/loggingLevel,value=INFO"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== API Gateway Performance Tracker Completed ==="
  
  # Send alerts
  if [[ ${HIGH_ERROR_APIS} -gt 0 ]]; then
    send_slack_alert "⚠️ ${HIGH_ERROR_APIS} API(s) with high error rates detected" "WARNING"
    send_email_alert "API Gateway Alert: High Error Rates" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${HIGH_LATENCY_APIS} -gt 0 ]]; then
    send_slack_alert "⚠️ ${HIGH_LATENCY_APIS} API(s) with high latency detected" "WARNING"
  fi
}

main "$@"

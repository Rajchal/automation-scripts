#!/bin/bash

################################################################################
# AWS CloudFront/CDN Monitor
# Monitors CloudFront distributions for error rates, cache hit ratio, TLS
# configuration, WAF association, origin health, and performance metrics.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/cloudfront-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/cloudfront-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
ERROR_RATE_WARN="${ERROR_RATE_WARN:-5}"              # % 4XX+5XX errors
CACHE_HIT_WARN="${CACHE_HIT_WARN:-80}"               # % minimum cache hit ratio
ORIGIN_LATENCY_WARN="${ORIGIN_LATENCY_WARN:-2000}"  # milliseconds
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_DISTRIBUTIONS=0
DISABLED_DISTRIBUTIONS=0
HIGH_ERROR_RATE_DISTROS=0
LOW_CACHE_HIT_DISTROS=0
NO_WAF_ATTACHED=0
TLS_CONFIG_ISSUES=0
UNHEALTHY_ORIGINS=0

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
      "title": "CloudFront Alert",
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
    echo "AWS CloudFront/CDN Monitor"
    echo "=========================="
    echo "Generated: $(date)"
    echo "Lookback Period: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Error Rate Warning: ${ERROR_RATE_WARN}%"
    echo "  Cache Hit Ratio Warning: <${CACHE_HIT_WARN}%"
    echo "  Origin Latency Warning: ${ORIGIN_LATENCY_WARN}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_distributions() {
  aws cloudfront list-distributions \
    --output json 2>/dev/null || echo '{"DistributionList":{"Items":[]}}'
}

get_distribution() {
  local distribution_id="$1"
  aws cloudfront get-distribution \
    --id "${distribution_id}" \
    --output json 2>/dev/null || echo '{}'
}

get_distribution_config() {
  local distribution_id="$1"
  aws cloudfront get-distribution-config \
    --id "${distribution_id}" \
    --output json 2>/dev/null || echo '{}'
}

list_distribution_tags() {
  local resource_arn="$1"
  aws cloudfront list-tags-for-resource \
    --resource "${resource_arn}" \
    --output json 2>/dev/null || echo '{"Tags":{"Items":[]}}'
}

get_cloudfront_metrics() {
  local distribution_id="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/CloudFront \
    --metric-name "${metric_name}" \
    --dimensions Name=DistributionId,Value="${distribution_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average \
    --region us-east-1 \
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

monitor_distributions() {
  log_message INFO "Starting CloudFront distribution monitoring"
  
  {
    echo "=== CLOUDFRONT DISTRIBUTION INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local distributions_json
  distributions_json=$(list_distributions)
  
  local distribution_count
  distribution_count=$(echo "${distributions_json}" | jq '.DistributionList.Quantity // 0' 2>/dev/null)
  
  TOTAL_DISTRIBUTIONS=${distribution_count}
  
  if [[ ${distribution_count} -eq 0 ]]; then
    {
      echo "No CloudFront distributions found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Distributions: ${distribution_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local distributions
  distributions=$(echo "${distributions_json}" | jq -c '.DistributionList.Items[]' 2>/dev/null)
  
  while IFS= read -r distribution; do
    [[ -z "${distribution}" ]] && continue
    
    local distro_id distro_domain_name enabled
    distro_id=$(echo "${distribution}" | jq_safe '.Id')
    distro_domain_name=$(echo "${distribution}" | jq_safe '.DomainName')
    enabled=$(echo "${distribution}" | jq_safe '.Enabled')
    
    log_message INFO "Analyzing distribution: ${distro_id}"
    
    {
      echo "=== DISTRIBUTION: ${distro_id} ==="
      echo ""
      echo "Domain Name: ${distro_domain_name}"
      echo "Enabled: ${enabled}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${enabled}" != "true" ]]; then
      ((DISABLED_DISTRIBUTIONS++))
      {
        printf "%b⚠️  Distribution Disabled%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "%b✓ Distribution Enabled%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get detailed configuration
    analyze_distribution_config "${distro_id}"
    
    # Check performance metrics
    analyze_performance_metrics "${distro_id}"
    
    # Check origins
    check_origins "${distro_id}"
    
    # Check TLS configuration
    check_tls_config "${distro_id}"
    
    # Check WAF association
    check_waf_association "${distro_id}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${distributions}"
}

analyze_distribution_config() {
  local distribution_id="$1"
  
  local dist_detail
  dist_detail=$(get_distribution "${distribution_id}")
  
  local dist_config
  dist_config=$(echo "${dist_detail}" | jq '.Distribution.DistributionConfig' 2>/dev/null)
  
  if [[ -z "${dist_config}" || "${dist_config}" == "null" ]]; then
    {
      echo "Configuration: Unable to retrieve"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Get cache behaviors
  local cache_behaviors
  cache_behaviors=$(echo "${dist_config}" | jq '.CacheBehaviors | length' 2>/dev/null || echo "0")
  
  local default_cache_behavior
  default_cache_behavior=$(echo "${dist_config}" | jq '.DefaultCacheBehavior.ViewerProtocolPolicy' 2>/dev/null)
  
  {
    echo "Configuration:"
    echo "  Default Cache Behavior: ${default_cache_behavior}"
    echo "  Additional Cache Behaviors: ${cache_behaviors}"
  } >> "${OUTPUT_FILE}"
  
  # Check HTTP to HTTPS redirect
  if [[ "${default_cache_behavior}" != "https-only" ]] && [[ "${default_cache_behavior}" != "redirect-to-https" ]]; then
    ((TLS_CONFIG_ISSUES++))
    {
      printf "  %b⚠️  Not forcing HTTPS%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Get comment
  local comment
  comment=$(echo "${dist_config}" | jq_safe '.Comment')
  
  if [[ -n "${comment}" ]]; then
    {
      echo "  Comment: ${comment}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_performance_metrics() {
  local distribution_id="$1"
  
  {
    echo "Performance Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get request count
  local request_json
  request_json=$(get_cloudfront_metrics "${distribution_id}" "Requests")
  
  local total_requests
  total_requests=$(echo "${request_json}" | calculate_sum)
  
  {
    echo "  Total Requests: ${total_requests}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${total_requests} -eq 0 ]]; then
    {
      echo "  No traffic data available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Get bytes downloaded
  local bytes_json
  bytes_json=$(get_cloudfront_metrics "${distribution_id}" "BytesDownloaded")
  
  local total_bytes
  total_bytes=$(echo "${bytes_json}" | calculate_sum)
  
  local bytes_gb
  bytes_gb=$(echo "scale=2; ${total_bytes} / 1073741824" | bc -l 2>/dev/null || echo "0")
  
  {
    echo "  Bytes Downloaded: ${bytes_gb} GB"
  } >> "${OUTPUT_FILE}"
  
  # Get 4XX errors
  local error_4xx_json
  error_4xx_json=$(get_cloudfront_metrics "${distribution_id}" "4xxErrorRate")
  
  local error_4xx_rate
  error_4xx_rate=$(echo "${error_4xx_json}" | calculate_avg)
  
  # Get 5XX errors
  local error_5xx_json
  error_5xx_json=$(get_cloudfront_metrics "${distribution_id}" "5xxErrorRate")
  
  local error_5xx_rate
  error_5xx_rate=$(echo "${error_5xx_json}" | calculate_avg)
  
  local total_error_rate
  total_error_rate=$(echo "scale=2; ${error_4xx_rate} + ${error_5xx_rate}" | bc -l 2>/dev/null || echo "0")
  
  {
    echo "  Error Rates:"
    echo "    4XX: ${error_4xx_rate}%"
    echo "    5XX: ${error_5xx_rate}%"
    echo "    Total: ${total_error_rate}%"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${total_error_rate} > ${ERROR_RATE_WARN}" | bc -l) )); then
    ((HIGH_ERROR_RATE_DISTROS++))
    {
      printf "    %b⚠️  High error rate%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Distribution ${distribution_id} error rate: ${total_error_rate}%"
  fi
  
  # Get cache statistics
  local cache_hit_json
  cache_hit_json=$(get_cloudfront_metrics "${distribution_id}" "CacheHitRate")
  
  local cache_hit_rate
  cache_hit_rate=$(echo "${cache_hit_json}" | calculate_avg)
  
  {
    echo "  Cache Hit Rate: ${cache_hit_rate}%"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${cache_hit_rate} < ${CACHE_HIT_WARN}" | bc -l) )); then
    ((LOW_CACHE_HIT_DISTROS++))
    {
      printf "  %b⚠️  Low cache hit ratio%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Distribution ${distribution_id} cache hit rate: ${cache_hit_rate}%"
  else
    {
      printf "  %b✓ Cache performance healthy%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Get origin latency
  local latency_json
  latency_json=$(get_cloudfront_metrics "${distribution_id}" "OriginLatency")
  
  local origin_latency_ms
  origin_latency_ms=$(echo "${latency_json}" | calculate_avg)
  
  {
    echo "  Origin Latency: ${origin_latency_ms}ms"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${origin_latency_ms} > ${ORIGIN_LATENCY_WARN}" | bc -l) )); then
    {
      printf "  %b⚠️  High origin latency%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Distribution ${distribution_id} origin latency: ${origin_latency_ms}ms"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_origins() {
  local distribution_id="$1"
  
  {
    echo "Origins:"
  } >> "${OUTPUT_FILE}"
  
  local dist_detail
  dist_detail=$(get_distribution "${distribution_id}")
  
  local origins
  origins=$(echo "${dist_detail}" | jq -c '.Distribution.DistributionConfig.Origins.Items[]' 2>/dev/null)
  
  if [[ -z "${origins}" ]]; then
    {
      echo "  No origins configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r origin; do
    [[ -z "${origin}" ]] && continue
    
    local origin_id origin_domain custom_header
    origin_id=$(echo "${origin}" | jq_safe '.Id')
    origin_domain=$(echo "${origin}" | jq_safe '.DomainName')
    
    {
      echo "  Origin: ${origin_id}"
      echo "    Domain: ${origin_domain}"
    } >> "${OUTPUT_FILE}"
    
    # Check origin type
    local origin_type
    origin_type=$(echo "${origin}" | jq -r 'if .S3OriginConfig then "S3" elif .CustomOriginConfig then "Custom" else "Unknown" end' 2>/dev/null)
    
    {
      echo "    Type: ${origin_type}"
    } >> "${OUTPUT_FILE}"
    
    # Check custom origin config
    if [[ "${origin_type}" == "Custom" ]]; then
      local origin_protocol http_port https_port
      origin_protocol=$(echo "${origin}" | jq_safe '.CustomOriginConfig.OriginProtocolPolicy')
      http_port=$(echo "${origin}" | jq_safe '.CustomOriginConfig.HTTPPort')
      https_port=$(echo "${origin}" | jq_safe '.CustomOriginConfig.HTTPSPort')
      
      {
        echo "    Protocol: ${origin_protocol}"
        echo "    HTTP Port: ${http_port}"
        echo "    HTTPS Port: ${https_port}"
      } >> "${OUTPUT_FILE}"
      
      if [[ "${origin_protocol}" != "https-only" ]]; then
        ((TLS_CONFIG_ISSUES++))
        {
          printf "    %b⚠️  Not using HTTPS only%b\n" "${YELLOW}" "${NC}"
        } >> "${OUTPUT_FILE}"
      fi
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${origins}"
}

check_tls_config() {
  local distribution_id="$1"
  
  {
    echo "TLS Configuration:"
  } >> "${OUTPUT_FILE}"
  
  local dist_detail
  dist_detail=$(get_distribution "${distribution_id}")
  
  local dist_config
  dist_config=$(echo "${dist_detail}" | jq '.Distribution.DistributionConfig' 2>/dev/null)
  
  # Check viewer protocol policy
  local viewer_protocol_policy
  viewer_protocol_policy=$(echo "${dist_config}" | jq_safe '.DefaultCacheBehavior.ViewerProtocolPolicy')
  
  {
    echo "  Viewer Protocol Policy: ${viewer_protocol_policy}"
  } >> "${OUTPUT_FILE}"
  
  # Check TLS version
  local min_tls_version
  min_tls_version=$(echo "${dist_config}" | jq_safe '.ViewerCertificate.MinimumProtocolVersion // "N/A"')
  
  {
    echo "  Minimum TLS Version: ${min_tls_version}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${min_tls_version}" != "TLSv1.2_2021" ]] && [[ "${min_tls_version}" != "TLSv1.2_2019-02" ]]; then
    ((TLS_CONFIG_ISSUES++))
    {
      printf "  %b⚠️  Consider upgrading TLS version%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  else
    {
      printf "  %b✓ TLS version acceptable%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Check certificate
  local cert_source
  cert_source=$(echo "${dist_config}" | jq -r '.ViewerCertificate | keys[0]' 2>/dev/null)
  
  {
    echo "  Certificate Source: ${cert_source}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_waf_association() {
  local distribution_id="$1"
  
  {
    echo "WAF Association:"
  } >> "${OUTPUT_FILE}"
  
  local dist_detail
  dist_detail=$(get_distribution "${distribution_id}")
  
  local waf_id
  waf_id=$(echo "${dist_detail}" | jq_safe '.Distribution.DistributionConfig.WebACLId')
  
  if [[ -z "${waf_id}" || "${waf_id}" == "null" ]]; then
    ((NO_WAF_ATTACHED++))
    {
      printf "  %b⚠️  No WAF associated%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Distribution ${distribution_id} has no WAF attached"
  else
    {
      echo "  WAF ACL ID: ${waf_id}"
      printf "  %b✓ WAF is associated%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== CLOUDFRONT SUMMARY ==="
    echo ""
    printf "Total Distributions: %d\n" "${TOTAL_DISTRIBUTIONS}"
    printf "Disabled Distributions: %d\n" "${DISABLED_DISTRIBUTIONS}"
    printf "High Error Rate: %d\n" "${HIGH_ERROR_RATE_DISTROS}"
    printf "Low Cache Hit Ratio: %d\n" "${LOW_CACHE_HIT_DISTROS}"
    printf "No WAF Attached: %d\n" "${NO_WAF_ATTACHED}"
    printf "TLS Configuration Issues: %d\n" "${TLS_CONFIG_ISSUES}"
    echo ""
    
    if [[ ${HIGH_ERROR_RATE_DISTROS} -gt 0 ]]; then
      printf "%b[CRITICAL] CDN error rates high%b\n" "${RED}" "${NC}"
    elif [[ ${TLS_CONFIG_ISSUES} -gt 0 ]] || [[ ${NO_WAF_ATTACHED} -gt 0 ]]; then
      printf "%b[WARNING] Security or performance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All distributions operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${HIGH_ERROR_RATE_DISTROS} -gt 0 ]]; then
      echo "Error Rate Reduction:"
      echo "  • Review origin health and connectivity"
      echo "  • Check origin server logs for errors"
      echo "  • Verify origin security groups allow CloudFront IPs"
      echo "  • Implement error caching policies"
      echo "  • Add custom error pages for common errors"
      echo "  • Monitor origin application logs"
      echo "  • Use CloudFront access logs for debugging"
      echo "  • Configure origin timeout appropriately"
      echo ""
    fi
    
    if [[ ${LOW_CACHE_HIT_DISTROS} -gt 0 ]]; then
      echo "Cache Hit Ratio Optimization:"
      echo "  • Review cache control headers on origin"
      echo "  • Increase cache TTL where appropriate"
      echo "  • Ignore query strings if not needed"
      echo "  • Normalize headers (case-sensitivity)"
      echo "  • Use CloudFront cache behaviors effectively"
      echo "  • Implement cache-busting strategies"
      echo "  • Monitor cache invalidation frequency"
      echo "  • Use versioned asset URLs for static content"
      echo "  • Enable compression for text content"
      echo ""
    fi
    
    if [[ ${NO_WAF_ATTACHED} -gt 0 ]]; then
      echo "WAF Security Implementation:"
      echo "  • Associate AWS WAF with all distributions"
      echo "  • Implement IP reputation lists"
      echo "  • Enable rate-based rule sets"
      echo "  • Protect against SQL injection"
      echo "  • Protect against XSS attacks"
      echo "  • Monitor WAF logs for blocked requests"
      echo "  • Implement custom rules for your application"
      echo "  • Test WAF rules in count mode first"
      echo "  • Review false positive blocked requests"
      echo ""
    fi
    
    if [[ ${TLS_CONFIG_ISSUES} -gt 0 ]]; then
      echo "TLS Configuration Hardening:"
      echo "  • Enforce HTTPS for all traffic"
      echo "  • Set minimum TLS version to TLSv1.2 or higher"
      echo "  • Use latest certificate compatibility"
      echo "  • Use ACM certificates for managed renewal"
      echo "  • Monitor certificate expiration"
      echo "  • Enable HSTS via custom headers"
      echo "  • Implement HTTP to HTTPS redirect"
      echo "  • Use custom SSL policy for compatible ciphers"
      echo ""
    fi
    
    echo "Performance Optimization:"
    echo "  • Enable gzip compression for text content"
    echo "  • Use CloudFront geographic restrictions"
    echo "  • Implement Lambda@Edge for customization"
    echo "  • Use field-level encryption for sensitive data"
    echo "  • Optimize origin response headers"
    echo "  • Use proper cache-control headers"
    echo "  • Implement cookie-based cache behavior"
    echo "  • Monitor and adjust origin timeout/keep-alive"
    echo ""
    
    echo "Security Best Practices:"
    echo "  • Restrict access using Origin Access Control (OAC)"
    echo "  • Use signed URLs or signed cookies for private content"
    echo "  • Enable access logging to S3"
    echo "  • Use VPC endpoints if origin is in VPC"
    echo "  • Implement DDoS protection (Shield/WAF)"
    echo "  • Monitor CloudFront access logs"
    echo "  • Use CloudWatch alarms for anomalies"
    echo "  • Audit distribution configurations regularly"
    echo ""
    
    echo "Monitoring & Observability:"
    echo "  • Enable CloudFront access logging"
    echo "  • Monitor error rates for anomalies"
    echo "  • Track cache hit ratio trends"
    echo "  • Set CloudWatch alarms for 5XX errors"
    echo "  • Monitor origin latency"
    echo "  • Review WAF metrics and blocked requests"
    echo "  • Use CloudWatch Insights for log analysis"
    echo "  • Monitor bandwidth utilization"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • CloudFront pricing: data transfer + requests"
    echo "  • Use CloudFront instead of multiple origins"
    echo "  • Cache content efficiently to reduce origin load"
    echo "  • Use geographic pricing awareness"
    echo "  • Monitor unused distributions"
    echo "  • Clean up old cache behaviors"
    echo "  • Use Lambda@Edge sparingly (additional charges)"
    echo "  • Consider Lightsail for simpler use cases"
    echo ""
    
    echo "High Availability:"
    echo "  • Use multiple origins with failover"
    echo "  • Implement origin health checks"
    echo "  • Configure appropriate timeout values"
    echo "  • Use auto-healing with origin failover"
    echo "  • Monitor origin availability"
    echo "  • Test disaster recovery procedures"
    echo "  • Use geographically distributed origins"
    echo ""
    
    echo "Integration Points:"
    echo "  • S3 for static content delivery"
    echo "  • ELB/ALB for dynamic content origins"
    echo "  • API Gateway for API distribution"
    echo "  • Lambda@Edge for edge computing"
    echo "  • WAF for security"
    echo "  • Shield Standard/Advanced for DDoS"
    echo "  • CloudWatch for monitoring"
    echo "  • Route 53 for DNS routing"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== CloudFront Monitor Started ==="
  
  write_header
  monitor_distributions
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS CloudFront Documentation:"
    echo "  https://docs.aws.amazon.com/cloudfront/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== CloudFront Monitor Completed ==="
  
  # Send alerts
  if [[ ${HIGH_ERROR_RATE_DISTROS} -gt 0 ]]; then
    send_slack_alert "🚨 ${HIGH_ERROR_RATE_DISTROS} CloudFront distribution(s) with high error rates" "CRITICAL"
    send_email_alert "CloudFront Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${TLS_CONFIG_ISSUES} -gt 0 ]] || [[ ${NO_WAF_ATTACHED} -gt 0 ]]; then
    send_slack_alert "⚠️ CloudFront security issues: ${TLS_CONFIG_ISSUES} TLS issues, ${NO_WAF_ATTACHED} without WAF" "WARNING"
  fi
}

main "$@"

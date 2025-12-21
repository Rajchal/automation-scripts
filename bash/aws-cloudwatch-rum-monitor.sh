#!/bin/bash

################################################################################
# AWS CloudWatch RUM Application Monitor
# Analyzes CloudWatch Real User Monitoring (RUM) metrics to detect performance
# anomalies, track user experience, identify bottlenecks, and provide optimization.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/rum-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/rum-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Performance thresholds (ms)
LCP_WARN="${LCP_WARN:-2500}"                     # Largest Contentful Paint
FID_WARN="${FID_WARN:-100}"                      # First Input Delay
CLS_WARN="${CLS_WARN:-0.1}"                      # Cumulative Layout Shift (0-1 scale)
TTFB_WARN="${TTFB_WARN:-600}"                    # Time to First Byte
DOM_INTERACTIVE_WARN="${DOM_INTERACTIVE_WARN:-3000}"  # DOM Interactive
PAGE_LOAD_WARN="${PAGE_LOAD_WARN:-5000}"         # Full page load

# Error thresholds
ERROR_RATE_WARN="${ERROR_RATE_WARN:-5}"          # % errors
JS_ERROR_WARN="${JS_ERROR_WARN:-2}"              # % JS errors

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

list_rum_apps() {
  aws rum list-app-monitors \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"AppMonitorSummaryList":[]}'
}

describe_rum_app() {
  local app_name="$1"
  aws rum get-app-monitor \
    --name "${app_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_rum_metrics() {
  local app_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/RUM \
    --metric-name "${metric_name}" \
    --dimensions Name=AppMonitorName,Value="${app_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Average,Maximum,Minimum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
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
      "title": "CloudWatch RUM Alert",
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
    echo "CloudWatch RUM Performance Analysis"
    echo "==================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Performance Thresholds (Good):"
    echo "  LCP (Largest Contentful Paint): < ${LCP_WARN}ms"
    echo "  FID (First Input Delay): < ${FID_WARN}ms"
    echo "  CLS (Cumulative Layout Shift): < ${CLS_WARN}"
    echo "  TTFB (Time to First Byte): < ${TTFB_WARN}ms"
    echo "  Page Load Time: < ${PAGE_LOAD_WARN}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

monitor_rum_apps() {
  log_message INFO "Starting RUM application monitoring"
  
  {
    echo "=== WEB APPLICATION MONITORING ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local apps_json
  apps_json=$(list_rum_apps)
  
  local app_names
  app_names=$(echo "${apps_json}" | jq -r '.AppMonitorSummaryList[]?.Name' 2>/dev/null)
  
  if [[ -z "${app_names}" ]]; then
    log_message WARN "No RUM applications found in region ${REGION}"
    {
      echo "Status: No RUM applications configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_apps=0
  local apps_with_issues=0
  
  while IFS= read -r app_name; do
    [[ -z "${app_name}" ]] && continue
    ((total_apps++))
    
    log_message INFO "Analyzing RUM app: ${app_name}"
    
    local app_desc
    app_desc=$(describe_rum_app "${app_name}")
    
    local app_id status created_date domain_list
    app_id=$(echo "${app_desc}" | jq_safe '.AppMonitor.Id')
    status=$(echo "${app_desc}" | jq_safe '.AppMonitor.State')
    created_date=$(echo "${app_desc}" | jq_safe '.AppMonitor.CreatedTime')
    domain_list=$(echo "${app_desc}" | jq -r '.AppMonitor.AppMonitorConfiguration.AllowCookies // false')
    
    {
      echo "Application: ${app_name}"
      echo "ID: ${app_id}"
      printf "Status: %s\n" "${status}"
      echo "Created: ${created_date}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get Core Web Vitals metrics
    local lcp_json fid_json cls_json ttfb_json page_load_json
    lcp_json=$(get_rum_metrics "${app_name}" "LargestContentfulPaint")
    fid_json=$(get_rum_metrics "${app_name}" "FirstInputDelay")
    cls_json=$(get_rum_metrics "${app_name}" "CumulativeLayoutShift")
    ttfb_json=$(get_rum_metrics "${app_name}" "TimeToFirstByte")
    page_load_json=$(get_rum_metrics "${app_name}" "PageLoadTime")
    
    local lcp_avg fid_avg cls_avg ttfb_avg page_load_avg
    lcp_avg=$(echo "${lcp_json}" | calculate_avg)
    fid_avg=$(echo "${fid_json}" | calculate_avg)
    cls_avg=$(echo "${cls_json}" | calculate_avg)
    ttfb_avg=$(echo "${ttfb_json}" | calculate_avg)
    page_load_avg=$(echo "${page_load_json}" | calculate_avg)
    
    {
      echo "Core Web Vitals (${LOOKBACK_HOURS}h avg):"
      echo "  LCP: ${lcp_avg}ms (target: <${LCP_WARN}ms)"
      echo "  FID: ${fid_avg}ms (target: <${FID_WARN}ms)"
      echo "  CLS: ${cls_avg} (target: <${CLS_WARN})"
      echo "  TTFB: ${ttfb_avg}ms (target: <${TTFB_WARN}ms)"
      echo "  Page Load: ${page_load_avg}ms (target: <${PAGE_LOAD_WARN}ms)"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check for performance issues
    local issues=0
    {
      echo "Performance Analysis:"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${lcp_avg} > ${LCP_WARN}" | bc -l) )); then
      {
        printf "%b  ⚠️  High LCP: %.0f ms (target <${LCP_WARN})%b\n" "${YELLOW}" "${lcp_avg}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ((issues++))
      ((apps_with_issues++))
      log_message WARN "App ${app_name} has high LCP: ${lcp_avg}ms"
    fi
    
    if (( $(echo "${fid_avg} > ${FID_WARN}" | bc -l) )); then
      {
        printf "%b  ⚠️  High FID: %.0f ms (target <${FID_WARN})%b\n" "${YELLOW}" "${fid_avg}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ((issues++))
      ((apps_with_issues++))
    fi
    
    if (( $(echo "${cls_avg} > ${CLS_WARN}" | bc -l) )); then
      {
        printf "%b  ⚠️  High CLS: %.3f (target <${CLS_WARN})%b\n" "${YELLOW}" "${cls_avg}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ((issues++))
      ((apps_with_issues++))
    fi
    
    if (( $(echo "${ttfb_avg} > ${TTFB_WARN}" | bc -l) )); then
      {
        printf "%b  ⚠️  High TTFB: %.0f ms (target <${TTFB_WARN})%b\n" "${YELLOW}" "${ttfb_avg}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ((issues++))
      ((apps_with_issues++))
    fi
    
    if (( $(echo "${page_load_avg} > ${PAGE_LOAD_WARN}" | bc -l) )); then
      {
        printf "%b  ⚠️  Slow Page Load: %.0f ms (target <${PAGE_LOAD_WARN})%b\n" "${YELLOW}" "${page_load_avg}" "${NC}"
      } >> "${OUTPUT_FILE}"
      ((issues++))
      ((apps_with_issues++))
    fi
    
    if [[ ${issues} -eq 0 ]]; then
      {
        echo "  ✓ All metrics within acceptable range"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Error tracking
    local js_error_json http_error_json
    js_error_json=$(get_rum_metrics "${app_name}" "JsErrors")
    http_error_json=$(get_rum_metrics "${app_name}" "HttpErrors")
    
    local js_error_avg http_error_avg
    js_error_avg=$(echo "${js_error_json}" | calculate_avg)
    http_error_avg=$(echo "${http_error_json}" | calculate_avg)
    
    {
      echo "Error Metrics:"
      echo "  JS Errors: ${js_error_avg}%"
      echo "  HTTP Errors: ${http_error_avg}%"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${js_error_avg} > ${JS_ERROR_WARN}" | bc -l) )); then
      {
        echo "  ⚠️  High JS error rate detected"
      } >> "${OUTPUT_FILE}"
      ((apps_with_issues++))
      log_message WARN "App ${app_name} has high JS error rate: ${js_error_avg}%"
    fi
    
    {
      echo ""
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${app_names}"
  
  # Summary
  {
    echo ""
    echo "=== MONITORING SUMMARY ==="
    echo "Total Applications: ${total_apps}"
    echo "Applications with Issues: ${apps_with_issues}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_guide() {
  {
    echo "=== PERFORMANCE OPTIMIZATION GUIDE ==="
    echo ""
    echo "Improving LCP (Largest Contentful Paint):"
    echo "  • Optimize image sizes and formats (WebP, AVIF)"
    echo "  • Defer non-critical JavaScript execution"
    echo "  • Use lazy loading for below-the-fold content"
    echo "  • Implement server-side rendering (SSR) or pre-rendering"
    echo "  • Optimize CSS delivery (critical CSS, async non-critical)"
    echo "  • Upgrade web server performance or use CDN"
    echo ""
    echo "Improving FID (First Input Delay):"
    echo "  • Break up long JavaScript tasks (>50ms)"
    echo "  • Use web workers for heavy computations"
    echo "  • Implement request prioritization"
    echo "  • Optimize third-party scripts (ads, analytics)"
    echo "  • Consider code splitting and lazy loading"
    echo ""
    echo "Improving CLS (Cumulative Layout Shift):"
    echo "  • Set explicit width/height on images and videos"
    echo "  • Avoid inserting content above existing content"
    echo "  • Use CSS transforms for animations"
    echo "  • Ensure fonts load without layout shift (font-display: swap)"
    echo "  • Avoid dynamic ad insertion"
    echo ""
    echo "Improving TTFB (Time to First Byte):"
    echo "  • Upgrade to CloudFront with origin shields"
    echo "  • Optimize backend response time (database queries)"
    echo "  • Implement server-side caching (Redis, ElastiCache)"
    echo "  • Use geographical distribution (multi-region)"
    echo "  • Monitor backend bottlenecks with X-Ray"
    echo ""
    echo "General Best Practices:"
    echo "  • Enable CloudFront compression (gzip, brotli)"
    echo "  • Use HTTP/2 and HTTP/3 (QUIC) protocols"
    echo "  • Implement Connection: keep-alive"
    echo "  • Minimize JavaScript bundles (code splitting)"
    echo "  • Monitor Core Web Vitals with RUM data"
    echo "  • Segment performance by URL/device/browser"
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitoring_setup() {
  {
    echo ""
    echo "=== RECOMMENDED MONITORING SETUP ==="
    echo ""
    echo "1. Enable RUM Data Collection:"
    echo "   aws rum create-app-monitor --name my-app \\"
    echo "     --domain list=myapp.example.com \\"
    echo "     --rum-javascript-config allow-cookies=true"
    echo ""
    echo "2. Set Up CloudWatch Alarms:"
    echo "   aws cloudwatch put-metric-alarm --alarm-name high-lcp \\"
    echo "     --metric-name LargestContentfulPaint \\"
    echo "     --namespace AWS/RUM --threshold 2500"
    echo ""
    echo "3. Create Dashboards:"
    echo "   • Core Web Vitals trends (LCP, FID, CLS)"
    echo "   • Error rates by type"
    echo "   • User experience by geography"
    echo "   • Performance by URL/page type"
    echo "   • Browser/device breakdown"
    echo ""
    echo "4. Integrate with Application Insights:"
    echo "   • Correlate RUM metrics with backend performance (X-Ray)"
    echo "   • Track business metrics alongside performance"
    echo "   • Analyze impact on user behavior/conversions"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== CloudWatch RUM Monitor Started ==="
  
  write_header
  monitor_rum_apps
  optimization_guide
  monitoring_setup
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "Additional Resources:"
    echo "  • Google Web Vitals: https://web.dev/vitals/"
    echo "  • AWS RUM Documentation: https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch-RUM.html"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== CloudWatch RUM Monitor Completed ==="
}

main "$@"

#!/bin/bash

################################################################################
# AWS WAF Rule Analyzer
# Analyzes WAF WebACLs, rules, rate limiting, blocked requests, identifies
# false positives, provides rule optimization, and tracks security metrics.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
SCOPE="${WAF_SCOPE:-REGIONAL}"  # REGIONAL or CLOUDFRONT
OUTPUT_FILE="/tmp/waf-analyzer-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/waf-analyzer.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
BLOCK_RATE_WARN="${BLOCK_RATE_WARN:-10}"           # % of requests blocked
RATE_LIMIT_THRESHOLD="${RATE_LIMIT_THRESHOLD:-2000}"  # requests per 5 min
FALSE_POSITIVE_THRESHOLD="${FALSE_POSITIVE_THRESHOLD:-5}"  # count
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
TOTAL_WEBACLS=0
TOTAL_RULES=0
BLOCKED_REQUESTS=0
ALLOWED_REQUESTS=0
RATE_LIMITED_REQUESTS=0

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
      "title": "WAF Alert",
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
    echo "AWS WAF Rule Analyzer"
    echo "====================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Scope: ${SCOPE}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Block Rate Warning: ${BLOCK_RATE_WARN}%"
    echo "  Rate Limit: ${RATE_LIMIT_THRESHOLD} req/5min"
    echo "  False Positive Threshold: ${FALSE_POSITIVE_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_webacls() {
  if [[ "${SCOPE}" == "CLOUDFRONT" ]]; then
    aws wafv2 list-web-acls \
      --scope CLOUDFRONT \
      --region us-east-1 \
      --output json 2>/dev/null || echo '{"WebACLs":[]}'
  else
    aws wafv2 list-web-acls \
      --scope REGIONAL \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{"WebACLs":[]}'
  fi
}

get_webacl() {
  local name="$1"
  local id="$2"
  
  if [[ "${SCOPE}" == "CLOUDFRONT" ]]; then
    aws wafv2 get-web-acl \
      --name "${name}" \
      --id "${id}" \
      --scope CLOUDFRONT \
      --region us-east-1 \
      --output json 2>/dev/null || echo '{}'
  else
    aws wafv2 get-web-acl \
      --name "${name}" \
      --id "${id}" \
      --scope REGIONAL \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{}'
  fi
}

get_waf_metrics() {
  local webacl_name="$1"
  local metric_name="$2"
  local rule_name="${3:-}"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  local dimensions
  if [[ -n "${rule_name}" ]]; then
    dimensions="Name=WebACL,Value=${webacl_name} Name=Rule,Value=${rule_name} Name=Region,Value=${REGION}"
  else
    dimensions="Name=WebACL,Value=${webacl_name} Name=Region,Value=${REGION}"
  fi
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/WAFV2 \
    --metric-name "${metric_name}" \
    --dimensions ${dimensions} \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() {
  jq -r '.Datapoints[].Sum' 2>/dev/null | \
    awk '{s+=$1} END {printf "%.0f", s}'
}

get_sampled_requests() {
  local webacl_name="$1"
  local webacl_id="$2"
  local rule_id="$3"
  local max_items="${4:-100}"
  
  local start_time end_time
  start_time=$(date -u -d "1 hour ago" +%s)
  end_time=$(date -u +%s)
  
  if [[ "${SCOPE}" == "CLOUDFRONT" ]]; then
    aws wafv2 get-sampled-requests \
      --web-acl-arn "arn:aws:wafv2:us-east-1:$(aws sts get-caller-identity --query Account --output text):global/webacl/${webacl_name}/${webacl_id}" \
      --rule-metric-name "${rule_id}" \
      --scope CLOUDFRONT \
      --time-window StartTime=${start_time},EndTime=${end_time} \
      --max-items ${max_items} \
      --region us-east-1 \
      --output json 2>/dev/null || echo '{"SampledRequests":[]}'
  else
    aws wafv2 get-sampled-requests \
      --web-acl-arn "arn:aws:wafv2:${REGION}:$(aws sts get-caller-identity --query Account --output text):regional/webacl/${webacl_name}/${webacl_id}" \
      --rule-metric-name "${rule_id}" \
      --scope REGIONAL \
      --time-window StartTime=${start_time},EndTime=${end_time} \
      --max-items ${max_items} \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{"SampledRequests":[]}'
  fi
}

analyze_webacls() {
  log_message INFO "Starting WAF WebACL analysis"
  
  {
    echo "=== WEB ACL INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local webacls_json
  webacls_json=$(list_webacls)
  
  local webacl_count
  webacl_count=$(echo "${webacls_json}" | jq '.WebACLs | length' 2>/dev/null || echo "0")
  
  TOTAL_WEBACLS=${webacl_count}
  
  if [[ ${webacl_count} -eq 0 ]]; then
    log_message WARN "No WebACLs found in ${SCOPE} scope"
    {
      echo "Status: No WebACLs configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total WebACLs: ${webacl_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local webacls
  webacls=$(echo "${webacls_json}" | jq -c '.WebACLs[]' 2>/dev/null)
  
  while IFS= read -r webacl; do
    [[ -z "${webacl}" ]] && continue
    
    local acl_name acl_id
    acl_name=$(echo "${webacl}" | jq_safe '.Name')
    acl_id=$(echo "${webacl}" | jq_safe '.Id')
    
    log_message INFO "Analyzing WebACL: ${acl_name}"
    
    {
      echo "WebACL: ${acl_name}"
      echo "ID: ${acl_id}"
    } >> "${OUTPUT_FILE}"
    
    # Get detailed WebACL info
    local webacl_detail
    webacl_detail=$(get_webacl "${acl_name}" "${acl_id}")
    
    local default_action capacity
    default_action=$(echo "${webacl_detail}" | jq_safe '.WebACL.DefaultAction | keys[0]')
    capacity=$(echo "${webacl_detail}" | jq_safe '.WebACL.Capacity')
    
    {
      echo "Default Action: ${default_action}"
      echo "Capacity Used: ${capacity}/1500"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze rules
    analyze_rules "${acl_name}" "${acl_id}" "${webacl_detail}"
    
    # Get metrics
    analyze_webacl_metrics "${acl_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${webacls}"
}

analyze_rules() {
  local acl_name="$1"
  local acl_id="$2"
  local webacl_detail="$3"
  
  {
    echo "Rules:"
  } >> "${OUTPUT_FILE}"
  
  local rules
  rules=$(echo "${webacl_detail}" | jq -c '.WebACL.Rules[]' 2>/dev/null)
  
  if [[ -z "${rules}" ]]; then
    {
      echo "  No rules configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local rule_count=0
  
  while IFS= read -r rule; do
    [[ -z "${rule}" ]] && continue
    
    ((rule_count++))
    ((TOTAL_RULES++))
    
    local rule_name priority action
    rule_name=$(echo "${rule}" | jq_safe '.Name')
    priority=$(echo "${rule}" | jq_safe '.Priority')
    
    # Determine action
    if echo "${rule}" | jq -e '.Action.Block' >/dev/null 2>&1; then
      action="Block"
    elif echo "${rule}" | jq -e '.Action.Allow' >/dev/null 2>&1; then
      action="Allow"
    elif echo "${rule}" | jq -e '.Action.Count' >/dev/null 2>&1; then
      action="Count"
    elif echo "${rule}" | jq -e '.Action.Captcha' >/dev/null 2>&1; then
      action="Captcha"
    else
      action="Unknown"
    fi
    
    {
      echo "  Rule: ${rule_name}"
      echo "    Priority: ${priority}"
      echo "    Action: ${action}"
    } >> "${OUTPUT_FILE}"
    
    # Check for rate-based rule
    local rate_limit
    rate_limit=$(echo "${rule}" | jq_safe '.Statement.RateBasedStatement.Limit')
    
    if [[ -n "${rate_limit}" ]] && [[ "${rate_limit}" != "null" ]]; then
      {
        echo "    Type: Rate-Based Rule"
        echo "    Rate Limit: ${rate_limit} requests per 5 minutes"
      } >> "${OUTPUT_FILE}"
      
      if [[ ${rate_limit} -lt ${RATE_LIMIT_THRESHOLD} ]]; then
        {
          printf "    %b⚠️  Rate limit might be too restrictive%b\n" "${YELLOW}" "${NC}"
        } >> "${OUTPUT_FILE}"
      fi
    fi
    
    # Check for managed rule group
    local managed_group
    managed_group=$(echo "${rule}" | jq_safe '.Statement.ManagedRuleGroupStatement.Name')
    
    if [[ -n "${managed_group}" ]] && [[ "${managed_group}" != "null" ]]; then
      local vendor
      vendor=$(echo "${rule}" | jq_safe '.Statement.ManagedRuleGroupStatement.VendorName')
      {
        echo "    Type: Managed Rule Group"
        echo "    Group: ${managed_group}"
        echo "    Vendor: ${vendor}"
      } >> "${OUTPUT_FILE}"
    fi
    
    # Get rule metrics
    local blocked_count allowed_count
    blocked_count=$(get_waf_metrics "${acl_name}" "BlockedRequests" "${rule_name}" | calculate_sum)
    allowed_count=$(get_waf_metrics "${acl_name}" "AllowedRequests" "${rule_name}" | calculate_sum)
    
    {
      echo "    Blocked Requests (${LOOKBACK_HOURS}h): ${blocked_count}"
      echo "    Allowed Requests (${LOOKBACK_HOURS}h): ${allowed_count}"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${blocked_count} -gt 0 ]]; then
      {
        printf "    %b✓ Rule is actively blocking traffic%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    elif [[ "${action}" == "Block" ]]; then
      {
        printf "    %bℹ  Rule not triggered in analysis window%b\n" "${CYAN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${rules}"
  
  {
    echo "  Total Rules: ${rule_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_webacl_metrics() {
  local acl_name="$1"
  
  {
    echo "Traffic Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get overall metrics
  local allowed_json blocked_json counted_json
  allowed_json=$(get_waf_metrics "${acl_name}" "AllowedRequests")
  blocked_json=$(get_waf_metrics "${acl_name}" "BlockedRequests")
  counted_json=$(get_waf_metrics "${acl_name}" "CountedRequests")
  
  local allowed_total blocked_total counted_total
  allowed_total=$(echo "${allowed_json}" | calculate_sum)
  blocked_total=$(echo "${blocked_json}" | calculate_sum)
  counted_total=$(echo "${counted_json}" | calculate_sum)
  
  ALLOWED_REQUESTS=$((ALLOWED_REQUESTS + allowed_total))
  BLOCKED_REQUESTS=$((BLOCKED_REQUESTS + blocked_total))
  
  local total_requests
  total_requests=$((allowed_total + blocked_total + counted_total))
  
  {
    echo "  Total Requests: ${total_requests}"
    echo "  Allowed: ${allowed_total}"
    echo "  Blocked: ${blocked_total}"
    echo "  Counted: ${counted_total}"
  } >> "${OUTPUT_FILE}"
  
  # Calculate block rate
  if [[ ${total_requests} -gt 0 ]]; then
    local block_rate
    block_rate=$(echo "scale=2; ${blocked_total} * 100 / ${total_requests}" | bc -l)
    
    {
      echo "  Block Rate: ${block_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${block_rate} > ${BLOCK_RATE_WARN}" | bc -l) )); then
      {
        printf "  %b⚠️  High block rate detected - review for false positives%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "WebACL ${acl_name} has high block rate: ${block_rate}%"
    else
      {
        printf "  %b✓ Block rate within acceptable range%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

identify_false_positives() {
  log_message INFO "Analyzing potential false positives..."
  
  {
    echo "=== FALSE POSITIVE ANALYSIS ==="
    echo ""
    echo "Note: Manual review of sampled requests recommended"
    echo "Check CloudWatch Logs Insights for detailed request analysis"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Recommendations for false positive detection
  {
    echo "False Positive Detection Methods:"
    echo "  1. Enable WAF logging to S3/CloudWatch Logs"
    echo "  2. Review blocked requests from known legitimate sources"
    echo "  3. Analyze User-Agent patterns in blocked traffic"
    echo "  4. Check for high block rates on specific rules"
    echo "  5. Monitor customer complaints about access issues"
    echo "  6. Use Count mode to test rules before Block mode"
    echo ""
    echo "CloudWatch Logs Insights Query Examples:"
    echo ""
    echo "# Top blocked URIs"
    echo 'fields @timestamp, httpRequest.uri'
    echo 'filter action="BLOCK"'
    echo '| stats count() by httpRequest.uri'
    echo '| sort count desc'
    echo '| limit 20'
    echo ""
    echo "# Blocked requests by country"
    echo 'fields @timestamp, httpRequest.country'
    echo 'filter action="BLOCK"'
    echo '| stats count() by httpRequest.country'
    echo ""
    echo "# Blocked requests by IP"
    echo 'fields @timestamp, httpRequest.clientIp'
    echo 'filter action="BLOCK"'
    echo '| stats count() by httpRequest.clientIp'
    echo '| limit 20'
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    
    echo "Rule Ordering Best Practices:"
    echo "  • Lower priority numbers execute first (0 is highest)"
    echo "  • Place rate-limiting rules early (priority 0-10)"
    echo "  • IP reputation rules should run early (priority 10-20)"
    echo "  • Geo-blocking rules in middle (priority 20-50)"
    echo "  • Managed rule groups toward end (priority 50-100)"
    echo "  • Custom application rules last (priority 100+)"
    echo ""
    
    echo "Rule Efficiency:"
    echo "  • Use Count mode for testing before enabling Block"
    echo "  • Consolidate similar rules to reduce capacity"
    echo "  • Remove rules with zero matches after 30+ days"
    echo "  • Use scope-down statements to reduce processing"
    echo "  • Implement CAPTCHA for borderline requests"
    echo ""
    
    echo "Rate Limiting Optimization:"
    echo "  • API endpoints: 100-500 requests per 5 min per IP"
    echo "  • Login pages: 20-50 requests per 5 min per IP"
    echo "  • General web traffic: 2000-5000 requests per 5 min"
    echo "  • Adjust based on CloudWatch metrics and business needs"
    echo ""
    
    echo "Managed Rule Group Recommendations:"
    echo "  • AWS Core Rule Set (CRS): Essential baseline protection"
    echo "  • AWS Known Bad Inputs: Block common attack patterns"
    echo "  • AWS SQL Database: Protect against SQL injection"
    echo "  • AWS Linux/Windows OS: OS-specific protections"
    echo "  • AWS IP Reputation: Block known malicious IPs"
    echo "  • Review excluded rules quarterly"
    echo ""
    
    echo "Performance Optimization:"
    echo "  • Keep total capacity under 1000 (leave headroom)"
    echo "  • Use IP sets for allow/block lists instead of inline IPs"
    echo "  • Use regex pattern sets for efficient matching"
    echo "  • Enable sampled request logging for troubleshooting"
    echo "  • Consider AWS Firewall Manager for multi-account management"
    echo ""
    
    echo "Security Best Practices:"
    echo "  • Enable logging to S3 for compliance/forensics"
    echo "  • Set up CloudWatch alarms for unusual block rates"
    echo "  • Implement geo-blocking for non-served regions"
    echo "  • Use CAPTCHA challenges instead of hard blocks"
    echo "  • Review and update IP reputation lists monthly"
    echo "  • Enable AWS Shield Advanced for DDoS protection"
    echo "  • Integrate with AWS Security Hub for centralized security"
    echo ""
    
    echo "Testing & Validation:"
    echo "  • Use AWS WAF Simulator to test rules before deployment"
    echo "  • Implement staging WebACL for rule testing"
    echo "  • Monitor impact after rule changes for 48-72 hours"
    echo "  • Document rule purposes and business justification"
    echo "  • Conduct quarterly rule effectiveness reviews"
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== WAF ANALYSIS SUMMARY ==="
    echo ""
    printf "Total WebACLs: %d\n" "${TOTAL_WEBACLS}"
    printf "Total Rules: %d\n" "${TOTAL_RULES}"
    echo ""
    printf "Traffic (${LOOKBACK_HOURS}h):\n"
    printf "  Allowed Requests: %d\n" "${ALLOWED_REQUESTS}"
    printf "  Blocked Requests: %d\n" "${BLOCKED_REQUESTS}"
    
    if [[ $((ALLOWED_REQUESTS + BLOCKED_REQUESTS)) -gt 0 ]]; then
      local overall_block_rate
      overall_block_rate=$(echo "scale=2; ${BLOCKED_REQUESTS} * 100 / (${ALLOWED_REQUESTS} + ${BLOCKED_REQUESTS})" | bc -l)
      printf "  Overall Block Rate: %s%%\n" "${overall_block_rate}"
    fi
    
    echo ""
    
    if [[ ${BLOCKED_REQUESTS} -gt 0 ]]; then
      printf "%b[ACTIVE] WAF is actively protecting resources%b\n" "${GREEN}" "${NC}"
    else
      printf "%b[INFO] No blocked requests in analysis window%b\n" "${CYAN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== WAF Rule Analyzer Started ==="
  
  write_header
  analyze_webacls
  identify_false_positives
  optimization_recommendations
  generate_summary
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS WAF Documentation:"
    echo "  https://docs.aws.amazon.com/waf/"
    echo ""
    echo "Enable WAF Logging:"
    echo "  aws wafv2 put-logging-configuration \\"
    echo "    --logging-configuration ResourceArn=<webacl-arn>,LogDestinationConfigs=<s3-bucket-arn>"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== WAF Rule Analyzer Completed ==="
  
  # Send alerts for high block rates
  if [[ ${BLOCKED_REQUESTS} -gt 1000 ]]; then
    send_slack_alert "WAF blocked ${BLOCKED_REQUESTS} requests in last ${LOOKBACK_HOURS}h - review for attack patterns" "INFO"
  fi
}

main "$@"

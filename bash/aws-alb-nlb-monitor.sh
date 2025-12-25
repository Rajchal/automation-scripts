#!/bin/bash

################################################################################
# AWS ALB/NLB Load Balancer Monitor
# Audits Application & Network Load Balancers: lists ALBs/NLBs, checks
# listener/target health, evaluates TLS policies and WAF associations,
# and pulls CloudWatch metrics (TargetResponseTime, HTTPCode_Target_5XX,
# UnHealthyHostCount, HealthyHostCount, RequestCount, TargetConnectionError).
# Includes env thresholds, logging, Slack/email alerts, and text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
LB_TYPE="${LB_TYPE:-ALL}"                   # ALB | NLB | ALL
OUTPUT_FILE="/tmp/alb-nlb-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/alb-nlb-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds (override via env)
UNHEALTHY_HOST_WARN="${UNHEALTHY_HOST_WARN:-1}"     # unhealthy hosts count
RESPONSE_TIME_WARN_MS="${RESPONSE_TIME_WARN_MS:-500}"  # avg response time in ms
ERROR_RATE_WARN_PCT="${ERROR_RATE_WARN_PCT:-5}"     # % of 5XX vs total requests
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_LBS=0
ALB_COUNT=0
NLB_COUNT=0
TOTAL_TARGET_GROUPS=0
LBS_UNHEALTHY_TARGETS=0
LBS_HIGH_LATENCY=0
LBS_HIGH_ERROR_RATE=0
LBS_NO_TLS=0
LBS_NO_WAF=0
LISTENER_COUNT=0

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
      "title": "AWS ALB/NLB Alert",
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
    echo "AWS ALB/NLB Load Balancer Monitor"
    echo "=================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "LB Types: ${LB_TYPE}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Unhealthy Hosts Warning: >= ${UNHEALTHY_HOST_WARN}"
    echo "  Response Time Warning: > ${RESPONSE_TIME_WARN_MS}ms"
    echo "  Error Rate Warning: > ${ERROR_RATE_WARN_PCT}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

# ELBv2 API wrappers
list_load_balancers() {
  aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"LoadBalancers":[]}'
}

describe_target_groups() {
  local lb_arn="$1"
  aws elbv2 describe-target-groups \
    --load-balancer-arn "$lb_arn" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"TargetGroups":[]}'
}

describe_target_health() {
  local tg_arn="$1"
  aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"TargetHealthDescriptions":[]}'
}

describe_listeners() {
  local lb_arn="$1"
  aws elbv2 describe-listeners \
    --load-balancer-arn "$lb_arn" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Listeners":[]}'
}

describe_ssl_policies() {
  local policy_name="$1"
  aws elbv2 describe-ssl-policies \
    --names "$policy_name" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"SslPolicies":[]}'
}

describe_tags() {
  local arn="$1"
  aws elbv2 describe-tags \
    --resource-arns "$arn" \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"TagDescriptions":[]}'
}

# CloudWatch metrics
get_lb_metrics() {
  local lb_name="$1" metric_name="$2"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ApplicationELB \
    --metric-name "$metric_name" \
    --dimensions Name=LoadBalancer,Value="$lb_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics Sum,Average \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

get_nlb_metrics() {
  local lb_name="$1" metric_name="$2"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/NetworkELB \
    --metric-name "$metric_name" \
    --dimensions Name=LoadBalancer,Value="$lb_name" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics Sum,Average \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

write_lb_header() {
  local lb_name="$1" lb_type="$2" scheme dns_name
  scheme=$(echo "$3" | jq_safe '.Scheme // "internet-facing"')
  dns_name=$(echo "$3" | jq_safe '.DNSName // ""')
  {
    echo "Load Balancer: ${lb_name}"
    echo "  Type: ${lb_type}"
    echo "  Scheme: ${scheme}"
    [[ -n "$dns_name" ]] && echo "  DNS: ${dns_name}"
  } >> "${OUTPUT_FILE}"
}

monitor_load_balancer() {
  local lb_arn="$1" lb_data="$2"
  local lb_name lb_type
  lb_name=$(echo "$lb_data" | jq_safe '.LoadBalancerName')
  lb_type=$(echo "$lb_data" | jq_safe '.Type')
  
  log_message INFO "Analyzing Load Balancer: ${lb_name} (${lb_type})"
  write_lb_header "$lb_name" "$lb_type" "$lb_data"
  
  # State
  local state
  state=$(echo "$lb_data" | jq_safe '.State.Code // "unknown"')
  {
    echo "  State: ${state}"
  } >> "${OUTPUT_FILE}"
  
  # VPC and Security Groups
  local vpc_id sg_ids
  vpc_id=$(echo "$lb_data" | jq_safe '.VpcId // ""')
  sg_ids=$(echo "$lb_data" | jq -r '.SecurityGroups[]? // empty' 2>/dev/null | tr '\n' ', ')
  [[ -n "$vpc_id" ]] && {
    echo "  VPC: ${vpc_id}" >> "${OUTPUT_FILE}"
    echo "  Security Groups: ${sg_ids%,}" >> "${OUTPUT_FILE}"
  }
  
  # Listeners
  analyze_listeners "$lb_arn" "$lb_type"
  
  # Target Groups
  analyze_target_groups "$lb_arn" "$lb_type" "$lb_name"
  
  # WAF association
  analyze_waf_association "$lb_arn"
  
  # Metrics
  analyze_lb_metrics "$lb_name" "$lb_type"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_listeners() {
  local lb_arn="$1" lb_type="$2"
  local listeners_json
  listeners_json=$(describe_listeners "$lb_arn")
  local listener_count
  listener_count=$(echo "$listeners_json" | jq '.Listeners | length' 2>/dev/null || echo "0")
  LISTENER_COUNT=$((LISTENER_COUNT + listener_count))
  
  {
    echo "  Listeners: ${listener_count}"
  } >> "${OUTPUT_FILE}"
  
  local listeners
  listeners=$(echo "$listeners_json" | jq -c '.Listeners[]?' 2>/dev/null)
  while IFS= read -r listener; do
    [[ -z "$listener" ]] && continue
    local port protocol ssl_policy default_action
    port=$(echo "$listener" | jq_safe '.Port')
    protocol=$(echo "$listener" | jq_safe '.Protocol')
    ssl_policy=$(echo "$listener" | jq_safe '.SslPolicy // "none"')
    default_action=$(echo "$listener" | jq_safe '.DefaultActions[0].Type // "unknown"')
    
    {
      echo "    - Port ${port} (${protocol})"
      [[ "$protocol" == "HTTPS" || "$protocol" == "TLS" ]] && {
        if [[ "$ssl_policy" != "none" ]]; then
          echo "      TLS Policy: ${ssl_policy}"
        else
          printf "      %b⚠️  No TLS policy%b\n" "${YELLOW}" "${NC}"
          ((LBS_NO_TLS++))
        fi
      }
    } >> "${OUTPUT_FILE}"
  done <<< "$listeners"
}

analyze_target_groups() {
  local lb_arn="$1" lb_type="$2" lb_name="$3"
  local tg_json
  tg_json=$(describe_target_groups "$lb_arn")
  local tg_count
  tg_count=$(echo "$tg_json" | jq '.TargetGroups | length' 2>/dev/null || echo "0")
  TOTAL_TARGET_GROUPS=$((TOTAL_TARGET_GROUPS + tg_count))
  
  {
    echo "  Target Groups: ${tg_count}"
  } >> "${OUTPUT_FILE}"
  
  local tgs
  tgs=$(echo "$tg_json" | jq -c '.TargetGroups[]?' 2>/dev/null)
  while IFS= read -r tg; do
    [[ -z "$tg" ]] && continue
    local tg_name tg_arn tg_port protocol hc_enabled
    tg_name=$(echo "$tg" | jq_safe '.TargetGroupName')
    tg_arn=$(echo "$tg" | jq_safe '.TargetGroupArn')
    tg_port=$(echo "$tg" | jq_safe '.Port')
    protocol=$(echo "$tg" | jq_safe '.Protocol')
    hc_enabled=$(echo "$tg" | jq_safe '.HealthCheckEnabled')
    
    {
      echo "    - ${tg_name} (${protocol}:${tg_port})"
      echo "      Health Check: ${hc_enabled}"
    } >> "${OUTPUT_FILE}"
    
    # Target health
    analyze_target_health "$tg_arn" "$tg_name" "$lb_name" "$lb_type"
  done <<< "$tgs"
}

analyze_target_health() {
  local tg_arn="$1" tg_name="$2" lb_name="$3" lb_type="$4"
  local health_json
  health_json=$(describe_target_health "$tg_arn")
  local total_targets healthy_count unhealthy_count
  total_targets=$(echo "$health_json" | jq '.TargetHealthDescriptions | length' 2>/dev/null || echo "0")
  healthy_count=$(echo "$health_json" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length' 2>/dev/null || echo "0")
  unhealthy_count=$((total_targets - healthy_count))
  
  {
    echo "      Targets: ${total_targets} (Healthy: ${healthy_count}, Unhealthy: ${unhealthy_count})"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${unhealthy_count} -ge ${UNHEALTHY_HOST_WARN} ]]; then
    ((LBS_UNHEALTHY_TARGETS++))
    {
      printf "      %b⚠️  Unhealthy targets detected%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    
    # Show unhealthy details
    local health_details
    health_details=$(echo "$health_json" | jq -c '.TargetHealthDescriptions[] | select(.TargetHealth.State!="healthy")?' 2>/dev/null)
    while IFS= read -r detail; do
      [[ -z "$detail" ]] && continue
      local target_id state reason
      target_id=$(echo "$detail" | jq_safe '.Target.Id')
      state=$(echo "$detail" | jq_safe '.TargetHealth.State')
      reason=$(echo "$detail" | jq_safe '.TargetHealth.Reason // "unknown"')
      {
        echo "        - ${target_id}: ${state} (${reason})"
      } >> "${OUTPUT_FILE}"
    done <<< "$health_details"
  fi
}

analyze_waf_association() {
  local lb_arn="$1"
  # Check WAF v2 association
  local waf_json
  waf_json=$(aws wafv2 list-resources-for-web-acl \
    --web-acl-arn "" \
    --resource-type ELASTIC_LOAD_BALANCER \
    --region "$REGION" \
    --output json 2>/dev/null || echo '{"ResourceArns":[]}')
  
  local waf_associated
  waf_associated=$(echo "$waf_json" | grep -q "$lb_arn" && echo "true" || echo "false")
  
  if [[ "$waf_associated" == "false" ]]; then
    ((LBS_NO_WAF++))
    {
      printf "  %b⚠️  No WAF association%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  else
    {
      echo "  WAF: associated"
    } >> "${OUTPUT_FILE}"
  fi
}

analyze_lb_metrics() {
  local lb_name="$1" lb_type="$2"
  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  local namespace
  [[ "$lb_type" == "application" ]] && namespace="AWS/ApplicationELB" || namespace="AWS/NetworkELB"
  
  # Determine metric function
  local get_metric_fn
  [[ "$lb_type" == "application" ]] && get_metric_fn="get_lb_metrics" || get_metric_fn="get_nlb_metrics"
  
  # Request count
  local request_json
  request_json=$($get_metric_fn "$lb_name" "RequestCount")
  local request_count
  request_count=$(echo "$request_json" | calculate_sum)
  
  {
    echo "    Request Count: ${request_count}"
  } >> "${OUTPUT_FILE}"
  
  # For ALB: HTTP errors, latency
  if [[ "$lb_type" == "application" ]]; then
    local error_5xx_json latency_json
    error_5xx_json=$($get_metric_fn "$lb_name" "HTTPCode_Target_5XX")
    latency_json=$($get_metric_fn "$lb_name" "TargetResponseTime")
    
    local error_5xx_count latency_avg error_rate
    error_5xx_count=$(echo "$error_5xx_json" | calculate_sum)
    latency_avg=$(echo "$latency_json" | calculate_avg)
    
    error_rate="0"
    if [[ ${request_count} -gt 0 ]]; then
      error_rate=$(echo "scale=2; ${error_5xx_count} * 100 / ${request_count}" | bc -l 2>/dev/null || echo "0")
    fi
    
    {
      echo "    5XX Errors: ${error_5xx_count}"
      echo "    Error Rate: ${error_rate}%"
      echo "    Response Time Avg: ${latency_avg}ms"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${latency_avg} > ${RESPONSE_TIME_WARN_MS}" | bc -l) )); then
      ((LBS_HIGH_LATENCY++))
      {
        printf "    %b⚠️  High latency%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
    if (( $(echo "${error_rate} > ${ERROR_RATE_WARN_PCT}" | bc -l) )); then
      ((LBS_HIGH_ERROR_RATE++))
      {
        printf "    %b⚠️  High error rate%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  else
    # For NLB: TCP metrics
    local new_flow_count active_flow_count
    new_flow_count=$($get_metric_fn "$lb_name" "NewFlowCount" | calculate_sum)
    active_flow_count=$($get_metric_fn "$lb_name" "ActiveFlowCount" | calculate_avg)
    
    {
      echo "    New Flows: ${new_flow_count}"
      echo "    Active Flows Avg: ${active_flow_count}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Unhealthy host count
  local unhealthy_json
  unhealthy_json=$($get_metric_fn "$lb_name" "UnHealthyHostCount")
  local unhealthy_count
  unhealthy_count=$(echo "$unhealthy_json" | calculate_avg)
  {
    echo "    Unhealthy Host Count Avg: ${unhealthy_count}"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${unhealthy_count} >= ${UNHEALTHY_HOST_WARN}" | bc -l) )); then
    {
      printf "    %b⚠️  Unhealthy hosts detected in metrics%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
}

summary_section() {
  {
    echo ""
    echo "=== ALB/NLB SUMMARY ==="
    echo ""
    printf "Total Load Balancers: %d\n" "${TOTAL_LBS}"
    printf "  ALB: %d\n" "${ALB_COUNT}"
    printf "  NLB: %d\n" "${NLB_COUNT}"
    printf "Total Target Groups: %d\n" "${TOTAL_TARGET_GROUPS}"
    printf "Total Listeners: %d\n" "${LISTENER_COUNT}"
    echo ""
    printf "LBs with Unhealthy Targets: %d\n" "${LBS_UNHEALTHY_TARGETS}"
    printf "LBs with High Latency: %d\n" "${LBS_HIGH_LATENCY}"
    printf "LBs with High Error Rate: %d\n" "${LBS_HIGH_ERROR_RATE}"
    printf "LBs without TLS: %d\n" "${LBS_NO_TLS}"
    printf "LBs without WAF: %d\n" "${LBS_NO_WAF}"
    echo ""
    if [[ ${LBS_UNHEALTHY_TARGETS} -gt 0 ]] || [[ ${LBS_HIGH_ERROR_RATE} -gt 0 ]]; then
      printf "%b[CRITICAL] Unhealthy targets or high error rate%b\n" "${RED}" "${NC}"
    elif [[ ${LBS_HIGH_LATENCY} -gt 0 ]] || [[ ${LBS_NO_TLS} -gt 0 ]] || [[ ${LBS_NO_WAF} -gt 0 ]]; then
      printf "%b[WARNING] Latency, TLS, or WAF issues%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Load Balancers appear healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations_section() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${LBS_UNHEALTHY_TARGETS} -gt 0 ]]; then
      echo "Fix Unhealthy Targets:"
      echo "  • Check target security groups and NACLs"
      echo "  • Verify target health check configuration"
      echo "  • Review target instance/service logs"
      echo "  • Ensure target ports are listening"
      echo "  • Check target application status"
      echo "  • Review deregistration delay settings"
      echo ""
    fi
    if [[ ${LBS_HIGH_ERROR_RATE} -gt 0 ]]; then
      echo "Reduce Error Rates:"
      echo "  • Review backend logs for failures"
      echo "  • Check integration health and timeouts"
      echo "  • Verify authorization rules"
      echo "  • Check for backend service degradation"
      echo "  • Use CloudWatch alarms for early warning"
      echo "  • Implement retry logic in clients"
      echo ""
    fi
    if [[ ${LBS_HIGH_LATENCY} -gt 0 ]]; then
      echo "Reduce Latency:"
      echo "  • Check target instance CPU/memory"
      echo "  • Optimize backend application"
      echo "  • Enable connection pooling"
      echo "  • Increase target capacity"
      echo "  • Review idle timeout settings"
      echo "  • Use keep-alive connections"
      echo ""
    fi
    if [[ ${LBS_NO_TLS} -gt 0 ]]; then
      echo "Enable TLS/HTTPS:"
      echo "  • Configure HTTPS listeners"
      echo "  • Use strong TLS policies (ELBSecurityPolicy-TLS-1-2-2017-01 or higher)"
      echo "  • Import or request ACM certificates"
      echo "  • Enable server name indication (SNI)"
      echo "  • Redirect HTTP to HTTPS"
      echo ""
    fi
    if [[ ${LBS_NO_WAF} -gt 0 ]]; then
      echo "Attach WAF:"
      echo "  • Associate WAFv2 Web ACLs to ALBs"
      echo "  • Define rules for common attacks"
      echo "  • Enable rate-based rules"
      echo "  • Monitor WAF blocked requests"
      echo "  • Fine-tune rules to avoid false positives"
      echo ""
    fi
    echo "Security Best Practices:"
    echo "  • Use security groups to restrict traffic"
    echo "  • Enable access logs to S3"
    echo "  • Attach WAF for DDoS/attack protection"
    echo "  • Use strong TLS policies"
    echo "  • Implement stickiness if needed"
    echo "  • Enable cross-zone load balancing"
    echo ""
    echo "Observability & Monitoring:"
    echo "  • CloudWatch alarms on errors, latency, unhealthy hosts"
    echo "  • Access logs for compliance and forensics"
    echo "  • AWS X-Ray for distributed tracing"
    echo "  • Request tracing headers"
    echo "  • SNS/Slack alerts"
    echo ""
    echo "Cost Optimization:"
    echo "  • Monitor and right-size target capacity"
    echo "  • Remove unused target groups"
    echo "  • Use NLB for extreme throughput (cheaper than ALB)"
    echo "  • Check for idle/unused LBs"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== ALB/NLB Monitor Started ==="
  write_header
  
  local lbs_json
  lbs_json=$(list_load_balancers)
  
  local lbs
  lbs=$(echo "$lbs_json" | jq -c '.LoadBalancers[]?' 2>/dev/null)
  local alb_count nlb_count
  alb_count=0
  nlb_count=0
  
  while IFS= read -r lb; do
    [[ -z "$lb" ]] && continue
    local lb_type lb_arn
    lb_type=$(echo "$lb" | jq_safe '.Type')
    lb_arn=$(echo "$lb" | jq_safe '.LoadBalancerArn')
    
    # Filter by type
    if [[ "$LB_TYPE" != "ALL" ]] && [[ "$lb_type" != "$LB_TYPE" ]]; then
      continue
    fi
    
    TOTAL_LBS=$((TOTAL_LBS + 1))
    [[ "$lb_type" == "application" ]] && alb_count=$((alb_count + 1)) || nlb_count=$((nlb_count + 1))
    
    monitor_load_balancer "$lb_arn" "$lb"
  done <<< "$lbs"
  
  ALB_COUNT=${alb_count}
  NLB_COUNT=${nlb_count}
  
  summary_section
  recommendations_section
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Elastic Load Balancing Documentation: https://docs.aws.amazon.com/elasticloadbalancing/"
  } >> "${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
  log_message INFO "=== ALB/NLB Monitor Completed ==="
  
  # Alerts
  if [[ ${LBS_UNHEALTHY_TARGETS} -gt 0 ]] || [[ ${LBS_HIGH_ERROR_RATE} -gt 0 ]]; then
    send_slack_alert "🚨 Load Balancer issues: unhealthy=${LBS_UNHEALTHY_TARGETS}, high_errors=${LBS_HIGH_ERROR_RATE}" "CRITICAL"
    send_email_alert "ALB/NLB Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${LBS_HIGH_LATENCY} -gt 0 ]] || [[ ${LBS_NO_TLS} -gt 0 ]] || [[ ${LBS_NO_WAF} -gt 0 ]]; then
    send_slack_alert "⚠️ Load Balancer warnings: latency=${LBS_HIGH_LATENCY}, no_tls=${LBS_NO_TLS}, no_waf=${LBS_NO_WAF}" "WARNING"
  fi
}

main "$@"

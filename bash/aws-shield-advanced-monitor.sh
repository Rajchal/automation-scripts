#!/bin/bash

################################################################################
# AWS Shield Advanced Monitor
# Audits Shield Advanced protections: lists protected resources, coverage by
# resource type, recent attacks, DDoS cost protection, proactive engagement,
# health checks, WAF associations, and CloudWatch metrics (AWS/DDoSProtection
# DDoSDetected, AttackMitigated, DRTAccessRequested). Includes env thresholds,
# logging, Slack/email alerts, and a text report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"            # Shield is managed in us-east-1 (global)
OUTPUT_FILE="/tmp/shield-advanced-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/shield-advanced-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Thresholds (override via env)
ATTACK_COUNT_WARN="${ATTACK_COUNT_WARN:-1}"          # warn if attacks in window >=
DDOS_DETECTED_WARN="${DDOS_DETECTED_WARN:-1}"        # warn if DDoSDetected metric >=
DRT_REQUEST_WARN="${DRT_REQUEST_WARN:-1}"            # warn if DRTAccessRequested >=

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_PROTECTIONS=0
PROT_ALB=0
PROT_NLB=0
PROT_CF=0
PROT_R53=0
PROT_GA=0
RECENT_ATTACKS=0
PROTECTIONS_WITH_WAF=0
PROTECTIONS_WITH_HEALTHCHECK=0
PROTECTIONS_WITH_ISSUES=0

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
      "title": "AWS Shield Advanced Alert",
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
    echo "AWS Shield Advanced Monitor"
    echo "==========================="
    echo "Generated: $(date)"
    echo "Region (Shield control plane): ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Attacks Warning: >= ${ATTACK_COUNT_WARN}"
    echo "  DDoSDetected Metric Warning: >= ${DDOS_DETECTED_WARN}"
    echo "  DRT Access Requested Warning: >= ${DRT_REQUEST_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

# Shield API wrappers
list_protections() {
  aws shield list-protections \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Protections":[]}'
}

get_protection() {
  local prot_id="$1"
  aws shield describe-protection \
    --protection-id "$prot_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_subscription() {
  aws shield describe-subscription \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_attacks() {
  local start_ts end_ts
  end_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_ts=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)
  aws shield list-attacks \
    --start-time From="$start_ts" To="$end_ts" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"AttackSummaries":[]}'
}

describe_attack() {
  local attack_id="$1"
  aws shield describe-attack \
    --attack-id "$attack_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

# WAF association check
get_waf_acl_for_resource() {
  local resource_arn="$1"
  # Determine region for WAFv2 call: CloudFront must use us-east-1
  local waf_region
  if [[ "$resource_arn" == arn:aws:cloudfront:* ]]; then
    waf_region="us-east-1"
  else
    waf_region=$(echo "$resource_arn" | awk -F: '{print $4}')
  fi
  aws wafv2 get-web-acl-for-resource \
    --resource-arn "$resource_arn" \
    --region "$waf_region" \
    --output json 2>/dev/null || echo '{}'
}

# CloudWatch metrics
get_shield_metric() {
  local resource_arn="$1" metric_name="$2"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/DDoSProtection \
    --metric-name "$metric_name" \
    --dimensions Name=ResourceArn,Value="$resource_arn" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics Sum,Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}'; }
calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }

resource_type_from_arn() {
  local arn="$1"
  case "$arn" in
    arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*) echo "ALB" ;;
    arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*) echo "NLB" ;;
    arn:aws:cloudfront::*) echo "CLOUDFRONT" ;;
    arn:aws:route53:::hostedzone/*) echo "ROUTE53" ;;
    arn:aws:globalaccelerator:*:accelerator/*) echo "GLOBAL_ACCELERATOR" ;;
    *) echo "OTHER" ;;
  esac
}

write_protection_header() {
  local name="$1" arn="$2" type="$3"
  {
    echo "Protection: ${name}"
    echo "  Resource ARN: ${arn}"
    echo "  Type: ${type}"
  } >> "${OUTPUT_FILE}"
}

analyze_protection() {
  local prot_json="$1"
  local prot_name prot_id resource_arn prot_type
  prot_name=$(echo "$prot_json" | jq_safe '.Name')
  prot_id=$(echo "$prot_json" | jq_safe '.Id')
  resource_arn=$(echo "$prot_json" | jq_safe '.ResourceArn')
  prot_type=$(resource_type_from_arn "$resource_arn")

  case "$prot_type" in
    ALB) ((PROT_ALB++)) ;;
    NLB) ((PROT_NLB++)) ;;
    CLOUDFRONT) ((PROT_CF++)) ;;
    ROUTE53) ((PROT_R53++)) ;;
    GLOBAL_ACCELERATOR) ((PROT_GA++)) ;;
  esac
  TOTAL_PROTECTIONS=$((TOTAL_PROTECTIONS + 1))

  write_protection_header "$prot_name" "$resource_arn" "$prot_type"

  # Health checks
  local health_ids
  health_ids=$(echo "$prot_json" | jq -r '.HealthCheckIds[]?' 2>/dev/null)
  if [[ -n "$health_ids" ]]; then
    ((PROTECTIONS_WITH_HEALTHCHECK++))
    echo "  Health Checks:" >> "${OUTPUT_FILE}"
    while IFS= read -r h; do
      [[ -z "$h" ]] && continue
      echo "    - ${h}" >> "${OUTPUT_FILE}"
    done <<< "$health_ids"
  else
    printf "  %b⚠️  No health checks configured%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
    ((PROTECTIONS_WITH_ISSUES++))
  fi

  # WAF association
  local waf_json
  waf_json=$(get_waf_acl_for_resource "$resource_arn")
  local waf_name
  waf_name=$(echo "$waf_json" | jq_safe '.WebACL.Name')
  if [[ -n "$waf_name" && "$waf_name" != "null" ]]; then
    ((PROTECTIONS_WITH_WAF++))
    echo "  WAF: ${waf_name}" >> "${OUTPUT_FILE}"
  else
    printf "  %b⚠️  No WAF Web ACL associated%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi

  # Metrics
  analyze_metrics "$resource_arn"

  echo "" >> "${OUTPUT_FILE}"
}

analyze_metrics() {
  local resource_arn="$1"
  echo "  Metrics (${LOOKBACK_HOURS}h):" >> "${OUTPUT_FILE}"

  local ddos_json mitigated_json drt_json
  ddos_json=$(get_shield_metric "$resource_arn" "DDoSDetected")
  mitigated_json=$(get_shield_metric "$resource_arn" "AttackMitigated")
  drt_json=$(get_shield_metric "$resource_arn" "DRTAccessRequested")

  local ddos_sum mitigated_sum drt_sum
  ddos_sum=$(echo "$ddos_json" | calculate_sum)
  mitigated_sum=$(echo "$mitigated_json" | calculate_sum)
  drt_sum=$(echo "$drt_json" | calculate_sum)

  echo "    DDoSDetected: ${ddos_sum}" >> "${OUTPUT_FILE}"
  echo "    AttackMitigated: ${mitigated_sum}" >> "${OUTPUT_FILE}"
  echo "    DRTAccessRequested: ${drt_sum}" >> "${OUTPUT_FILE}"

  if (( $(echo "${ddos_sum} >= ${DDOS_DETECTED_WARN}" | bc -l) )); then
    printf "    %b⚠️  DDoS detected metric triggered%b\n" "${RED}" "${NC}" >> "${OUTPUT_FILE}"
    ((PROTECTIONS_WITH_ISSUES++))
  fi
  if (( $(echo "${drt_sum} >= ${DRT_REQUEST_WARN}" | bc -l) )); then
    printf "    %b⚠️  DRT access was requested%b\n" "${YELLOW}" "${NC}" >> "${OUTPUT_FILE}"
  fi
}

analyze_subscription() {
  local sub_json="$1"
  local auto_renew proactive_engagement cost_protection
  auto_renew=$(echo "$sub_json" | jq_safe '.Subscription.AutoRenew')
  proactive_engagement=$(echo "$sub_json" | jq_safe '.Subscription.ProactiveEngagementStatus')
  cost_protection=$(echo "$sub_json" | jq_safe '.Subscription.Limits[]? | select(.Type=="DDoS Response Team") | .Max')
  {
    echo "Subscription:"
    echo "  AutoRenew: ${auto_renew}"
    echo "  ProactiveEngagementStatus: ${proactive_engagement}"
    echo "  DDoS Cost Protection (if enrolled): ${cost_protection:-N/A}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_attacks() {
  local attacks_json="$1"
  local count
  count=$(echo "$attacks_json" | jq '.AttackSummaries | length' 2>/dev/null || echo "0")
  RECENT_ATTACKS=${count}
  {
    echo "Recent Attacks (last ${LOOKBACK_HOURS}h): ${count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${count} -eq 0 ]]; then
    echo "" >> "${OUTPUT_FILE}"
    return
  fi

  local attacks
  attacks=$(echo "$attacks_json" | jq -c '.AttackSummaries[]?' 2>/dev/null)
  while IFS= read -r atk; do
    [[ -z "$atk" ]] && continue
    local attack_id start end resource_arn
    attack_id=$(echo "$atk" | jq_safe '.AttackId')
    start=$(echo "$atk" | jq_safe '.StartTime')
    end=$(echo "$atk" | jq_safe '.EndTime // "ongoing"')
    resource_arn=$(echo "$atk" | jq_safe '.ResourceArn')
    echo "  - AttackId: ${attack_id}" >> "${OUTPUT_FILE}"
    echo "    Resource: ${resource_arn}" >> "${OUTPUT_FILE}"
    echo "    Start: ${start}" >> "${OUTPUT_FILE}"
    echo "    End: ${end}" >> "${OUTPUT_FILE}"
  done <<< "$attacks"
  echo "" >> "${OUTPUT_FILE}"
}

summary_section() {
  {
    echo "=== SHIELD SUMMARY ==="
    echo ""
    printf "Total Protections: %d\n" "${TOTAL_PROTECTIONS}"
    printf "  ALB: %d\n" "${PROT_ALB}"
    printf "  NLB: %d\n" "${PROT_NLB}"
    printf "  CloudFront: %d\n" "${PROT_CF}"
    printf "  Route53: %d\n" "${PROT_R53}"
    printf "  Global Accelerator: %d\n" "${PROT_GA}"
    echo ""
    printf "Protections with WAF: %d\n" "${PROTECTIONS_WITH_WAF}"
    printf "Protections with Health Checks: %d\n" "${PROTECTIONS_WITH_HEALTHCHECK}"
    printf "Recent Attacks: %d\n" "${RECENT_ATTACKS}"
    printf "Protections with Issues: %d\n" "${PROTECTIONS_WITH_ISSUES}"
    echo ""
    if [[ ${RECENT_ATTACKS} -ge ${ATTACK_COUNT_WARN} ]] || [[ ${PROTECTIONS_WITH_ISSUES} -gt 0 ]]; then
      printf "%b[CRITICAL] Attacks detected or configuration gaps%b\n" "${RED}" "${NC}"
    elif [[ ${PROTECTIONS_WITH_WAF} -lt ${TOTAL_PROTECTIONS} ]]; then
      printf "%b[WARNING] Some protections missing WAF%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Shield protections look healthy%b\n" "${GREEN}" "${NC}"
    fi
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations_section() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    if [[ ${RECENT_ATTACKS} -ge ${ATTACK_COUNT_WARN} ]]; then
      echo "Attack Response:"
      echo "  • Review Shield attack logs and vectors"
      echo "  • Validate WAF rules and rate limits"
      echo "  • Confirm health checks and failover paths"
      echo "  • Engage AWS DRT if needed"
      echo "  • Enable proactive engagement"
      echo ""
    fi
    if [[ ${PROTECTIONS_WITH_HEALTHCHECK} -lt ${TOTAL_PROTECTIONS} ]]; then
      echo "Add Health Checks:"
      echo "  • Configure Route53 health checks for protected endpoints"
      echo "  • Ensure failover policies are in place"
      echo "  • Monitor health check alarms"
      echo ""
    fi
    if [[ ${PROTECTIONS_WITH_WAF} -lt ${TOTAL_PROTECTIONS} ]]; then
      echo "Attach WAF:"
      echo "  • Associate WAFv2 Web ACLs with protected resources"
      echo "  • Enable managed rule groups and rate-based rules"
      echo "  • Tune exclusions to reduce false positives"
      echo ""
    fi
    echo "Subscription & Cost Protection:"
    echo "  • Ensure Shield Advanced subscription is active and set to AutoRenew"
    echo "  • Verify DDoS cost protection eligibility"
    echo "  • Enable proactive engagement"
    echo ""
    echo "Observability:"
    echo "  • Create CloudWatch alarms on DDoSDetected and AttackMitigated"
    echo "  • Stream Shield logs to S3 or SIEM"
    echo "  • Enable AWS Health notifications"
    echo "  • Set Slack/SNS for attack alerts"
    echo ""
    echo "Best Practices:"
    echo "  • Protect all internet-facing ALBs, CF distributions, and Route53 zones"
    echo "  • Use WAF + Shield layered defense"
    echo "  • Keep contact routing up to date for DRT"
    echo "  • Run regular game days to test response"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Shield Advanced Monitor Started ==="
  write_header

  local sub_json
  sub_json=$(get_subscription)
  analyze_subscription "$sub_json"

  local prot_list
  prot_list=$(list_protections)
  local protections
  protections=$(echo "$prot_list" | jq -c '.Protections[]?' 2>/dev/null)

  if [[ -z "$protections" ]]; then
    echo "No Shield Advanced protections found." >> "${OUTPUT_FILE}"
  else
    while IFS= read -r prot; do
      [[ -z "$prot" ]] && continue
      analyze_protection "$prot"
    done <<< "$protections"
  fi

  local attacks_json
  attacks_json=$(list_attacks)
  analyze_attacks "$attacks_json"

  summary_section
  recommendations_section
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Shield Advanced Documentation: https://docs.aws.amazon.com/waf/latest/developerguide/ddos-overview.html"
  } >> "${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
  log_message INFO "=== Shield Advanced Monitor Completed ==="

  # Alerts
  if [[ ${RECENT_ATTACKS} -ge ${ATTACK_COUNT_WARN} ]]; then
    send_slack_alert "🚨 Shield: ${RECENT_ATTACKS} attack(s) detected in last ${LOOKBACK_HOURS}h" "CRITICAL"
    send_email_alert "Shield Advanced Attack Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${PROTECTIONS_WITH_ISSUES} -gt 0 ]]; then
    send_slack_alert "⚠️ Shield gaps: issues=${PROTECTIONS_WITH_ISSUES}" "WARNING"
  fi
}

main "$@"

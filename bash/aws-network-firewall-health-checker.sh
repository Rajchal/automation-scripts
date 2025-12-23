#!/bin/bash

################################################################################
# AWS Network Firewall Health Checker
# Monitors Network Firewall endpoints, rule capacity, flow logs, failover
# status, and provides alerts for unhealthy firewalls.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/network-firewall-health-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/network-firewall-health.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
CAPACITY_WARN_PCT="${CAPACITY_WARN_PCT:-80}"        # % capacity utilization
PACKET_DROP_WARN="${PACKET_DROP_WARN:-100}"         # dropped packets
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_FIREWALLS=0
HEALTHY_FIREWALLS=0
UNHEALTHY_FIREWALLS=0
FIREWALLS_WITHOUT_LOGS=0
HIGH_CAPACITY_POLICIES=0

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
      "title": "Network Firewall Alert",
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
    echo "AWS Network Firewall Health Checker"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Capacity Warning: ${CAPACITY_WARN_PCT}%"
    echo "  Packet Drop Warning: ${PACKET_DROP_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_firewalls() {
  aws network-firewall list-firewalls \
    --region "${REGION}" \
    --max-results 100 \
    --output json 2>/dev/null || echo '{"Firewalls":[]}'
}

describe_firewall() {
  local arn="$1"
  aws network-firewall describe-firewall \
    --firewall-arn "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_firewall_policies() {
  aws network-firewall list-firewall-policies \
    --region "${REGION}" \
    --max-results 100 \
    --output json 2>/dev/null || echo '{"FirewallPolicies":[]}'
}

describe_firewall_policy() {
  local arn="$1"
  aws network-firewall describe-firewall-policy \
    --firewall-policy-arn "${arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_logging_configuration() {
  local firewall_arn="$1"
  aws network-firewall describe-logging-configuration \
    --firewall-arn "${firewall_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"LoggingConfiguration":{}}'
}

get_firewall_metrics() {
  local firewall_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/NetworkFirewall \
    --metric-name "${metric_name}" \
    --dimensions Name=FirewallName,Value="${firewall_name}" Name=AvailabilityZone,Value=all \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average \
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

monitor_firewalls() {
  log_message INFO "Starting Network Firewall monitoring"
  
  {
    echo "=== NETWORK FIREWALL INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local firewalls_json
  firewalls_json=$(list_firewalls)
  
  local count
  count=$(echo "${firewalls_json}" | jq '.Firewalls | length' 2>/dev/null || echo "0")
  
  TOTAL_FIREWALLS=${count}
  
  if [[ ${count} -eq 0 ]]; then
    {
      echo "No Network Firewalls found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Firewalls: ${count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local firewalls
  firewalls=$(echo "${firewalls_json}" | jq -c '.Firewalls[]' 2>/dev/null)
  
  while IFS= read -r firewall; do
    [[ -z "${firewall}" ]] && continue
    
    local name arn
    name=$(echo "${firewall}" | jq_safe '.FirewallName')
    arn=$(echo "${firewall}" | jq_safe '.FirewallArn')
    
    log_message INFO "Analyzing firewall: ${name}"
    
    # Get detailed info
    local detail_json
    detail_json=$(describe_firewall "${arn}")
    
    local status vpc_id policy_arn delete_protection change_protection subnet_change_protection
    status=$(echo "${detail_json}" | jq_safe '.FirewallStatus.Status')
    vpc_id=$(echo "${detail_json}" | jq_safe '.Firewall.VpcId')
    policy_arn=$(echo "${detail_json}" | jq_safe '.Firewall.FirewallPolicyArn')
    delete_protection=$(echo "${detail_json}" | jq_safe '.Firewall.DeleteProtection')
    change_protection=$(echo "${detail_json}" | jq_safe '.Firewall.FirewallPolicyChangeProtection')
    subnet_change_protection=$(echo "${detail_json}" | jq_safe '.Firewall.SubnetChangeProtection')
    
    {
      echo "Firewall: ${name}"
      echo "ARN: ${arn}"
      echo "VPC: ${vpc_id}"
      echo "Status: ${status}"
      echo "Policy ARN: ${policy_arn}"
      echo "Delete Protection: ${delete_protection}"
      echo "Policy Change Protection: ${change_protection}"
      echo "Subnet Change Protection: ${subnet_change_protection}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check firewall health
    if [[ "${status}" == "READY" ]]; then
      ((HEALTHY_FIREWALLS++))
      {
        printf "%b✓ Firewall Ready%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      ((UNHEALTHY_FIREWALLS++))
      {
        printf "%b⚠️  Firewall Status: %s%b\n" "${RED}" "${status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Firewall ${name} status: ${status}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze endpoints
    analyze_endpoints "${detail_json}" "${name}"
    
    # Check logging
    check_logging "${arn}" "${name}"
    
    # Get metrics
    analyze_firewall_metrics "${name}"
    
    # Analyze policy
    analyze_policy "${policy_arn}" "${name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${firewalls}"
}

analyze_endpoints() {
  local detail_json="$1"
  local firewall_name="$2"
  
  {
    echo "Endpoints:"
  } >> "${OUTPUT_FILE}"
  
  local endpoints
  endpoints=$(echo "${detail_json}" | jq -c '.FirewallStatus.SyncStates | to_entries[]' 2>/dev/null)
  
  if [[ -z "${endpoints}" ]]; then
    {
      echo "  No endpoint information available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r endpoint; do
    [[ -z "${endpoint}" ]] && continue
    
    local az attachment_status endpoint_id
    az=$(echo "${endpoint}" | jq_safe '.key')
    attachment_status=$(echo "${endpoint}" | jq_safe '.value.Attachment.Status')
    endpoint_id=$(echo "${endpoint}" | jq_safe '.value.Attachment.EndpointId')
    
    {
      echo "  AZ: ${az}"
      echo "    Endpoint ID: ${endpoint_id}"
      echo "    Status: ${attachment_status}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${attachment_status}" == "READY" ]]; then
      {
        printf "    %b✓ Endpoint Ready%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "    %b⚠️  Endpoint Status: %s%b\n" "${YELLOW}" "${attachment_status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Firewall ${firewall_name} endpoint in ${az} status: ${attachment_status}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${endpoints}"
}

check_logging() {
  local firewall_arn="$1"
  local firewall_name="$2"
  
  {
    echo "Logging Configuration:"
  } >> "${OUTPUT_FILE}"
  
  local logging_json
  logging_json=$(describe_logging_configuration "${firewall_arn}")
  
  local log_destinations
  log_destinations=$(echo "${logging_json}" | jq '.LoggingConfiguration.LogDestinationConfigs | length' 2>/dev/null || echo "0")
  
  if [[ ${log_destinations} -eq 0 ]]; then
    ((FIREWALLS_WITHOUT_LOGS++))
    {
      printf "  %b⚠️  No logging configured%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Firewall ${firewall_name} has no logging configured"
  else
    {
      echo "  Configured Destinations: ${log_destinations}"
    } >> "${OUTPUT_FILE}"
    
    local configs
    configs=$(echo "${logging_json}" | jq -c '.LoggingConfiguration.LogDestinationConfigs[]' 2>/dev/null)
    
    while IFS= read -r config; do
      [[ -z "${config}" ]] && continue
      
      local log_type log_destination
      log_type=$(echo "${config}" | jq_safe '.LogType')
      log_destination=$(echo "${config}" | jq_safe '.LogDestination.logDestination')
      
      {
        echo "    - Type: ${log_type}"
        echo "      Destination: ${log_destination}"
      } >> "${OUTPUT_FILE}"
      
    done <<< "${configs}"
    
    {
      printf "  %b✓ Logging enabled%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_firewall_metrics() {
  local firewall_name="$1"
  
  {
    echo "Traffic Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get packet metrics
  local packets_json dropped_json rejected_json
  packets_json=$(get_firewall_metrics "${firewall_name}" "Packets")
  dropped_json=$(get_firewall_metrics "${firewall_name}" "DroppedPackets")
  rejected_json=$(get_firewall_metrics "${firewall_name}" "RejectedPackets")
  
  local total_packets dropped_packets rejected_packets
  total_packets=$(echo "${packets_json}" | calculate_sum)
  dropped_packets=$(echo "${dropped_json}" | calculate_sum)
  rejected_packets=$(echo "${rejected_json}" | calculate_sum)
  
  {
    echo "  Total Packets: ${total_packets}"
    echo "  Dropped Packets: ${dropped_packets}"
    echo "  Rejected Packets: ${rejected_packets}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${dropped_packets} -gt ${PACKET_DROP_WARN} ]]; then
    {
      printf "  %b⚠️  High packet drop count%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Firewall ${firewall_name} dropped ${dropped_packets} packets"
  fi
  
  if [[ ${total_packets} -gt 0 ]]; then
    local drop_rate
    drop_rate=$(echo "scale=2; ${dropped_packets} * 100 / ${total_packets}" | bc -l 2>/dev/null || echo "0")
    {
      echo "  Drop Rate: ${drop_rate}%"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_policy() {
  local policy_arn="$1"
  local firewall_name="$2"
  
  {
    echo "Firewall Policy:"
  } >> "${OUTPUT_FILE}"
  
  local policy_json
  policy_json=$(describe_firewall_policy "${policy_arn}")
  
  local policy_name consumed_capacity
  policy_name=$(echo "${policy_json}" | jq_safe '.FirewallPolicyResponse.FirewallPolicyName')
  consumed_capacity=$(echo "${policy_json}" | jq_safe '.FirewallPolicyResponse.ConsumedStatelessRuleCapacity // 0')
  
  {
    echo "  Name: ${policy_name}"
    echo "  Consumed Stateless Capacity: ${consumed_capacity} / 30000"
  } >> "${OUTPUT_FILE}"
  
  # Calculate capacity percentage
  if [[ ${consumed_capacity} -gt 0 ]]; then
    local capacity_pct
    capacity_pct=$(echo "scale=2; ${consumed_capacity} * 100 / 30000" | bc -l)
    
    {
      echo "  Capacity Usage: ${capacity_pct}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${capacity_pct} > ${CAPACITY_WARN_PCT}" | bc -l) )); then
      ((HIGH_CAPACITY_POLICIES++))
      {
        printf "  %b⚠️  High capacity usage%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Policy ${policy_name} capacity at ${capacity_pct}%"
    else
      {
        printf "  %b✓ Capacity healthy%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
  fi
  
  # Check rule groups
  local stateless_count stateful_count
  stateless_count=$(echo "${policy_json}" | jq '.FirewallPolicy.StatelessRuleGroupReferences | length' 2>/dev/null || echo "0")
  stateful_count=$(echo "${policy_json}" | jq '.FirewallPolicy.StatefulRuleGroupReferences | length' 2>/dev/null || echo "0")
  
  {
    echo "  Stateless Rule Groups: ${stateless_count}"
    echo "  Stateful Rule Groups: ${stateful_count}"
  } >> "${OUTPUT_FILE}"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== NETWORK FIREWALL SUMMARY ==="
    echo ""
    printf "Total Firewalls: %d\n" "${TOTAL_FIREWALLS}"
    printf "Healthy Firewalls: %d\n" "${HEALTHY_FIREWALLS}"
    printf "Unhealthy Firewalls: %d\n" "${UNHEALTHY_FIREWALLS}"
    printf "Firewalls Without Logging: %d\n" "${FIREWALLS_WITHOUT_LOGS}"
    printf "High Capacity Policies: %d\n" "${HIGH_CAPACITY_POLICIES}"
    echo ""
    
    if [[ ${UNHEALTHY_FIREWALLS} -gt 0 ]]; then
      printf "%b[CRITICAL] Firewall health issues detected%b\n" "${RED}" "${NC}"
    elif [[ ${FIREWALLS_WITHOUT_LOGS} -gt 0 ]] || [[ ${HIGH_CAPACITY_POLICIES} -gt 0 ]]; then
      printf "%b[WARNING] Configuration issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All firewalls operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${UNHEALTHY_FIREWALLS} -gt 0 ]]; then
      echo "Unhealthy Firewall Remediation:"
      echo "  • Check VPC subnet availability and routing"
      echo "  • Verify firewall policy is valid and within capacity"
      echo "  • Review CloudWatch logs for error messages"
      echo "  • Ensure IAM roles have required permissions"
      echo "  • Check for resource quotas (20 firewalls/region default)"
      echo ""
    fi
    
    if [[ ${FIREWALLS_WITHOUT_LOGS} -gt 0 ]]; then
      echo "Logging Configuration:"
      echo "  • Enable ALERT logs to CloudWatch or S3"
      echo "  • Enable FLOW logs for traffic analysis"
      echo "  • Use CloudWatch Logs Insights for querying"
      echo "  • Set up log retention policies (7-14 days typical)"
      echo "  • Enable logging for compliance and forensics"
      echo ""
    fi
    
    if [[ ${HIGH_CAPACITY_POLICIES} -gt 0 ]]; then
      echo "Capacity Management:"
      echo "  • Review and consolidate redundant rules"
      echo "  • Use IP sets instead of individual IPs"
      echo "  • Optimize regex patterns in rules"
      echo "  • Consider splitting policies across firewalls"
      echo "  • Stateless capacity limit: 30,000 units"
      echo "  • Stateful capacity limit: 30,000 units"
      echo ""
    fi
    
    echo "Security Best Practices:"
    echo "  • Enable delete protection on production firewalls"
    echo "  • Enable policy change protection"
    echo "  • Enable subnet change protection"
    echo "  • Use separate policies for different environments"
    echo "  • Implement default deny with explicit allow rules"
    echo "  • Use domain list filtering for web traffic"
    echo "  • Enable TLS inspection for encrypted traffic"
    echo "  • Tag firewalls for cost allocation"
    echo ""
    
    echo "Performance Optimization:"
    echo "  • Deploy firewall endpoints in each AZ"
    echo "  • Use stateless rules for simple filtering (faster)"
    echo "  • Use stateful rules for protocol inspection"
    echo "  • Monitor packet drop rates"
    echo "  • Scale horizontally by adding endpoints"
    echo "  • Review CloudWatch metrics for bottlenecks"
    echo ""
    
    echo "High Availability:"
    echo "  • Deploy endpoints in multiple AZs"
    echo "  • Use Gateway Load Balancer for centralized inspection"
    echo "  • Implement automated failover with route tables"
    echo "  • Test failover scenarios regularly"
    echo "  • Monitor endpoint health via CloudWatch"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • Pricing: $0.395/hour per endpoint + $0.065/GB processed"
    echo "  • Deploy only in required AZs"
    echo "  • Optimize rule complexity to reduce processing"
    echo "  • Use flow logs sampling for non-critical traffic"
    echo "  • Review and remove unused firewalls/policies"
    echo ""
    
    echo "Monitoring & Alerts:"
    echo "  • CloudWatch alarm on DroppedPackets"
    echo "  • Alarm on firewall status changes"
    echo "  • Monitor ConsumedStatelessRuleCapacity"
    echo "  • Track RejectedPackets for security events"
    echo "  • Enable AWS Config rules for compliance"
    echo "  • Integrate with Security Hub"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Network Firewall Health Checker Started ==="
  
  write_header
  monitor_firewalls
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Network Firewall Documentation:"
    echo "  https://docs.aws.amazon.com/network-firewall/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Network Firewall Health Checker Completed ==="
  
  # Send alerts
  if [[ ${UNHEALTHY_FIREWALLS} -gt 0 ]]; then
    send_slack_alert "🚨 ${UNHEALTHY_FIREWALLS} unhealthy Network Firewall(s) detected" "CRITICAL"
    send_email_alert "Network Firewall Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${FIREWALLS_WITHOUT_LOGS} -gt 0 ]]; then
    send_slack_alert "⚠️ ${FIREWALLS_WITHOUT_LOGS} firewall(s) without logging configured" "WARNING"
  fi
}

main "$@"

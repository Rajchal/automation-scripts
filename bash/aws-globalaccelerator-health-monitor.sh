#!/bin/bash

################################################################################
# AWS Global Accelerator Health Monitor
# Monitors Global Accelerator endpoints, endpoint groups, flow metrics,
# health status, and multi-region failover events with detailed reporting
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/globalaccelerator-health-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/globalaccelerator-health.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
UNHEALTHY_ENDPOINT_WARN="${UNHEALTHY_ENDPOINT_WARN:-1}"       # unhealthy endpoints threshold
FLOW_LOSS_WARN="${FLOW_LOSS_WARN:-5}"                         # % packet loss
FLOW_COUNT_ANOMALY="${FLOW_COUNT_ANOMALY:-50}"                # % change detection
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"          # seconds
HEALTH_CHECK_THRESHOLD="${HEALTH_CHECK_THRESHOLD:-3}"         # failures to mark unhealthy

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

list_accelerators() {
  aws globalaccelerator list-accelerators \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Accelerators":[]}'
}

describe_accelerator() {
  local accelerator_arn="$1"
  aws globalaccelerator describe-accelerator \
    --accelerator-arn "${accelerator_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_listeners() {
  local accelerator_arn="$1"
  aws globalaccelerator list-listeners \
    --accelerator-arn "${accelerator_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Listeners":[]}'
}

list_endpoint_groups() {
  local listener_arn="$1"
  aws globalaccelerator list-endpoint-groups \
    --listener-arn "${listener_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"EndpointGroups":[]}'
}

describe_endpoint_group() {
  local endpoint_group_arn="$1"
  aws globalaccelerator describe-endpoint-group \
    --endpoint-group-arn "${endpoint_group_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

describe_endpoint() {
  local endpoint_group_arn="$1"
  local endpoint_id="$2"
  aws globalaccelerator describe-endpoint \
    --endpoint-group-arn "${endpoint_group_arn}" \
    --endpoint-id "${endpoint_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_flow_logs() {
  local accelerator_name="$1"
  local start_time
  local end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws globalaccelerator get-flow-logs-s3-bucket \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_cw_metrics() {
  local accelerator_name="$1"
  local metric_name="$2"
  local start_time
  local end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/GlobalAccelerator" \
    --metric-name "${metric_name}" \
    --dimensions Name=Accelerator,Value="${accelerator_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Sum,Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_metric_avg() {
  local metric_json="$1"
  echo "${metric_json}" | jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

send_slack_alert() {
  local message="$1"
  local severity="$2"
  
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    return
  fi
  
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
      "title": "Global Accelerator Health Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  curl -X POST -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK}" 2>/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then
    return
  fi
  
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS Global Accelerator Health Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Health Check Interval: ${HEALTH_CHECK_INTERVAL}s"
    echo "Health Check Threshold: ${HEALTH_CHECK_THRESHOLD} failures"
    echo "Metric Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
  } > "${OUTPUT_FILE}"
}

monitor_accelerators() {
  log_message INFO "Starting Global Accelerator health monitoring"
  
  {
    echo "=== ACCELERATOR STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local total_accelerators=0
  local unhealthy_endpoints=0
  local disabled_endpoints=0
  local failed_endpoint_groups=0
  
  local accelerators_json
  accelerators_json=$(list_accelerators)
  
  local accelerator_arns
  accelerator_arns=$(echo "${accelerators_json}" | jq -r '.Accelerators[].AcceleratorArn' 2>/dev/null)
  
  if [[ -z "${accelerator_arns}" ]]; then
    log_message WARN "No Global Accelerators found in region ${REGION}"
    {
      echo "Status: No accelerators found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r accelerator_arn; do
    ((total_accelerators++))
    
    log_message INFO "Monitoring accelerator: ${accelerator_arn}"
    
    local accel_desc
    accel_desc=$(describe_accelerator "${accelerator_arn}")
    
    local accel_name
    local accel_status
    local accel_enabled
    local created_time
    local ip_address_type
    
    accel_name=$(echo "${accel_desc}" | jq_safe '.Accelerator.Name')
    accel_status=$(echo "${accel_desc}" | jq_safe '.Accelerator.Status')
    accel_enabled=$(echo "${accel_desc}" | jq_safe '.Accelerator.Enabled')
    created_time=$(echo "${accel_desc}" | jq_safe '.Accelerator.CreatedTime')
    ip_address_type=$(echo "${accel_desc}" | jq_safe '.Accelerator.IpAddressType')
    
    local status_color="${GREEN}"
    if [[ "${accel_status}" != "DEPLOYED" ]]; then
      status_color="${YELLOW}"
    fi
    
    if [[ "${accel_enabled}" != "true" ]]; then
      status_color="${RED}"
    fi
    
    {
      echo "Accelerator: ${accel_name}"
      printf "%bStatus: %s%b\n" "${status_color}" "${accel_status}" "${NC}"
      echo "Enabled: ${accel_enabled}"
      echo "Created: ${created_time}"
      echo "IP Type: ${ip_address_type}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get listeners
    local listeners_json
    listeners_json=$(list_listeners "${accelerator_arn}")
    
    local listener_arns
    listener_arns=$(echo "${listeners_json}" | jq -r '.Listeners[].ListenerArn' 2>/dev/null)
    
    if [[ -z "${listener_arns}" ]]; then
      {
        echo "Listeners: None"
        echo ""
      } >> "${OUTPUT_FILE}"
      continue
    fi
    
    {
      echo "Listeners:"
    } >> "${OUTPUT_FILE}"
    
    while IFS= read -r listener_arn; do
      [[ -z "${listener_arn}" ]] && continue
      
      local listener_port
      local listener_protocol
      listener_port=$(echo "${listeners_json}" | jq -r ".Listeners[] | select(.ListenerArn == \"${listener_arn}\") | .PortRanges[0].FromPort" 2>/dev/null || echo "N/A")
      listener_protocol=$(echo "${listeners_json}" | jq -r ".Listeners[] | select(.ListenerArn == \"${listener_arn}\") | .Protocol" 2>/dev/null || echo "N/A")
      
      {
        echo "  Protocol: ${listener_protocol}, Port: ${listener_port}"
      } >> "${OUTPUT_FILE}"
      
      # Get endpoint groups for this listener
      local endpoint_groups_json
      endpoint_groups_json=$(list_endpoint_groups "${listener_arn}")
      
      local endpoint_group_arns
      endpoint_group_arns=$(echo "${endpoint_groups_json}" | jq -r '.EndpointGroups[].EndpointGroupArn' 2>/dev/null)
      
      if [[ -z "${endpoint_group_arns}" ]]; then
        {
          echo "    Endpoint Groups: None"
        } >> "${OUTPUT_FILE}"
        continue
      fi
      
      {
        echo "    Endpoint Groups:"
      } >> "${OUTPUT_FILE}"
      
      while IFS= read -r endpoint_group_arn; do
        [[ -z "${endpoint_group_arn}" ]] && continue
        
        log_message INFO "Analyzing endpoint group: ${endpoint_group_arn}"
        
        local eg_desc
        eg_desc=$(describe_endpoint_group "${endpoint_group_arn}")
        
        local region_name
        local health_check_protocol
        local health_check_port
        local health_check_interval
        local threshold_count
        local endpoint_descriptions
        
        region_name=$(echo "${eg_desc}" | jq_safe '.EndpointGroup.EndpointGroupRegion')
        health_check_protocol=$(echo "${eg_desc}" | jq_safe '.EndpointGroup.HealthCheckProtocol')
        health_check_port=$(echo "${eg_desc}" | jq_safe '.EndpointGroup.HealthCheckPort')
        health_check_interval=$(echo "${eg_desc}" | jq_safe '.EndpointGroup.HealthCheckIntervalSeconds')
        threshold_count=$(echo "${eg_desc}" | jq_safe '.EndpointGroup.ThresholdCount')
        endpoint_descriptions=$(echo "${eg_desc}" | jq -r '.EndpointGroup.EndpointDescriptions[]?' 2>/dev/null)
        
        {
          echo "      Region: ${region_name}"
          echo "      Health Check: ${health_check_protocol}:${health_check_port} (interval: ${health_check_interval}s, threshold: ${threshold_count})"
          echo "      Endpoints:"
        } >> "${OUTPUT_FILE}"
        
        local group_healthy=true
        local group_unhealthy=0
        
        if [[ -n "${endpoint_descriptions}" ]]; then
          echo "${endpoint_descriptions}" | while IFS= read -r endpoint_line; do
            local endpoint_id
            local endpoint_addr
            local health_status
            local client_ip_preservation
            
            endpoint_id=$(echo "${endpoint_line}" | jq_safe '.EndpointId')
            endpoint_addr=$(echo "${endpoint_line}" | jq_safe '.Endpoint')
            health_status=$(echo "${endpoint_line}" | jq_safe '.HealthState')
            client_ip_preservation=$(echo "${endpoint_line}" | jq_safe '.ClientIPPreservationEnabled')
            
            local health_color="${GREEN}"
            if [[ "${health_status}" != "Healthy" ]]; then
              health_color="${RED}"
              group_healthy=false
              ((group_unhealthy++))
              ((unhealthy_endpoints++))
            fi
            
            printf "        %b%-50s Health: %s%b\n" \
              "${health_color}" "${endpoint_addr}" "${health_status}" "${NC}" >> "${OUTPUT_FILE}"
            
          done
        fi
        
        if [[ "${group_healthy}" == "false" ]]; then
          ((failed_endpoint_groups++))
          {
            echo ""
            echo "      ⚠️  WARNING: ${group_unhealthy} unhealthy endpoints"
          } >> "${OUTPUT_FILE}"
          log_message WARN "Endpoint group ${endpoint_group_arn} has ${group_unhealthy} unhealthy endpoints"
          local alert_msg="⚠️  Global Accelerator ${accel_name} - Region ${region_name} has ${group_unhealthy} unhealthy endpoints"
          send_slack_alert "${alert_msg}" "WARNING"
        fi
        
        {
          echo ""
        } >> "${OUTPUT_FILE}"
        
      done <<< "${endpoint_group_arns}"
      
    done <<< "${listener_arns}"
    
    {
      echo ""
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${accelerator_arns}"
  
  # Summary
  {
    echo ""
    echo "=== HEALTH SUMMARY ==="
    echo "Total Accelerators: ${total_accelerators}"
    echo "Unhealthy Endpoints: ${unhealthy_endpoints}"
    echo "Failed Endpoint Groups: ${failed_endpoint_groups}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${unhealthy_endpoints} -gt ${UNHEALTHY_ENDPOINT_WARN} ]]; then
    log_message CRITICAL "Unhealthy endpoints detected: ${unhealthy_endpoints}"
    local alert_msg="🔴 CRITICAL: Global Accelerator has ${unhealthy_endpoints} unhealthy endpoints"
    send_slack_alert "${alert_msg}" "CRITICAL"
    send_email_alert "Global Accelerator Health Alert" "${alert_msg}"
  fi
}

analyze_flow_metrics() {
  log_message INFO "Analyzing flow metrics"
  
  {
    echo ""
    echo "=== FLOW METRICS ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local accelerators_json
  accelerators_json=$(list_accelerators)
  
  local accelerator_names
  accelerator_names=$(echo "${accelerators_json}" | jq -r '.Accelerators[].Name' 2>/dev/null)
  
  if [[ -z "${accelerator_names}" ]]; then
    return
  fi
  
  while IFS= read -r accel_name; do
    [[ -z "${accel_name}" ]] && continue
    
    log_message INFO "Collecting flow metrics for: ${accel_name}"
    
    # New flows created
    local new_flows_json processed_bytes_in processed_bytes_out
    new_flows_json=$(get_cw_metrics "${accel_name}" "NewFlowCount")
    processed_bytes_in=$(get_cw_metrics "${accel_name}" "ProcessedBytesIn")
    processed_bytes_out=$(get_cw_metrics "${accel_name}" "ProcessedBytesOut")
    
    local new_flows_avg
    new_flows_avg=$(echo "${new_flows_json}" | jq -r '.Datapoints[].Sum' 2>/dev/null | \
      awk '{s+=$1; c++} END {if (c>0) printf "%.0f", s/c; else print "0"}')
    
    {
      echo "Accelerator: ${accel_name}"
      echo "New Flows (avg): ${new_flows_avg} flows/period"
      echo "Data processed (in/out): Bytes collected"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${accelerator_names}"
}

recommendations() {
  {
    echo ""
    echo "=== BEST PRACTICES ==="
    echo ""
    echo "• Monitor endpoint health status regularly"
    echo "• Set appropriate health check thresholds (typically 3-5 failures)"
    echo "• Implement traffic dials to control traffic distribution"
    echo "• Use Regional Endpoint Groups for better performance"
    echo "• Enable Client IP preservation for source IP logging"
    echo "• Monitor flow logs for anomalies and DDoS patterns"
    echo "• Set up CloudWatch alarms for unhealthy endpoints"
    echo "• Use Global Accelerator with ALB/NLB for optimal performance"
    echo "• Review listener port ranges for efficient traffic routing"
    echo "• Enable flow logs for traffic analysis and troubleshooting"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Global Accelerator Health Monitor Started ==="
  
  write_header
  monitor_accelerators
  analyze_flow_metrics
  recommendations
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Global Accelerator Health Monitor Completed ==="
}

main "$@"

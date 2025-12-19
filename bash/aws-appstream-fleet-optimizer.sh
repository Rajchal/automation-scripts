#!/bin/bash

################################################################################
# AWS AppStream 2.0 Fleet Optimizer
# Monitors fleet usage, session metrics, and provides optimization recommendations
# for AppStream 2.0 streaming instances and capacity planning
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/appstream-optimizer-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/appstream-optimizer.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
CPU_USAGE_WARN="${CPU_USAGE_WARN:-75}"
MEMORY_USAGE_WARN="${MEMORY_USAGE_WARN:-85}"
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-80}"
IDLE_INSTANCE_THRESHOLD="${IDLE_INSTANCE_THRESHOLD:-15}"     # minutes
COST_SAVE_THRESHOLD="${COST_SAVE_THRESHOLD:-20}"              # percent

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

list_fleets() {
  aws appstream list-fleets \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Fleets":[]}'
}

describe_fleet() {
  local fleet_name="$1"
  aws appstream describe-fleets \
    --names "${fleet_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Fleets":[]}'
}

list_fleet_instances() {
  local fleet_name="$1"
  aws appstream list-associated-fleets \
    --stack-name "${fleet_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Names":[]}'
}

describe_instances() {
  local fleet_name="$1"
  aws appstream describe-instances \
    --region "${REGION}" \
    --output json 2>/dev/null | jq ".Instances[] | select(.Name | startswith(\"${fleet_name}\"))"
}

get_cloudwatch_metrics() {
  local instance_id="$1"
  local metric_name="$2"
  local start_time
  local end_time
  
  start_time=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace "AWS/AppStream" \
    --metric-name "${metric_name}" \
    --dimensions Name=InstanceId,Value="${instance_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 300 \
    --statistics Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

list_user_sessions() {
  local stack_name="$1"
  aws appstream list-user-stack-associations \
    --stack-name "${stack_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"UserStackAssociations":[]}'
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
      "title": "AppStream 2.0 Optimization Alert",
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
    echo "AWS AppStream 2.0 Fleet Optimization Report"
    echo "============================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "CPU Warning: ${CPU_USAGE_WARN}%"
    echo "Memory Warning: ${MEMORY_USAGE_WARN}%"
    echo "Session Capacity Warning: ${SESSION_COUNT_WARN}%"
    echo "Idle Instance Threshold: ${IDLE_INSTANCE_THRESHOLD} minutes"
    echo ""
  } > "${OUTPUT_FILE}"
}

analyze_fleets() {
  log_message INFO "Starting AppStream 2.0 fleet analysis"
  
  {
    echo "=== FLEET SUMMARY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local total_fleets=0
  local total_instances=0
  local active_sessions=0
  local idle_instances=0
  local optimization_opportunities=0
  local potential_savings=0
  
  local fleets_json
  fleets_json=$(list_fleets)
  
  local fleet_names
  fleet_names=$(echo "${fleets_json}" | jq -r '.Fleets[].Name' 2>/dev/null)
  
  if [[ -z "${fleet_names}" ]]; then
    log_message WARN "No AppStream 2.0 fleets found in region ${REGION}"
    {
      echo "Status: No fleets found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r fleet_name; do
    ((total_fleets++))
    
    log_message INFO "Analyzing fleet: ${fleet_name}"
    
    local fleet_details
    fleet_details=$(describe_fleet "${fleet_name}")
    
    local fleet_type
    local instance_type
    local desired_capacity
    local running_capacity
    local available_capacity
    local state
    local created_time
    
    fleet_type=$(echo "${fleet_details}" | jq_safe '.Fleets[0].Type')
    instance_type=$(echo "${fleet_details}" | jq_safe '.Fleets[0].InstanceType')
    desired_capacity=$(echo "${fleet_details}" | jq_safe '.Fleets[0].DesiredCapacity')
    running_capacity=$(echo "${fleet_details}" | jq_safe '.Fleets[0].RunningCapacity')
    available_capacity=$(echo "${fleet_details}" | jq_safe '.Fleets[0].AvailableCapacity')
    state=$(echo "${fleet_details}" | jq_safe '.Fleets[0].State')
    created_time=$(echo "${fleet_details}" | jq_safe '.Fleets[0].CreatedTime')
    
    total_instances=$((total_instances + running_capacity))
    
    local cpu_avg=0
    local memory_avg=0
    local sessions_count=0
    local idle_count=0
    
    # Get instances for this fleet
    local instances_json
    instances_json=$(aws appstream list-instances --region "${REGION}" --output json 2>/dev/null || echo '{"Instances":[]}')
    
    local fleet_instances
    fleet_instances=$(echo "${instances_json}" | jq -r ".Instances[] | select(.Name | startswith(\"${fleet_name}\")) | .Id" 2>/dev/null)
    
    local instance_count=0
    local sum_cpu=0
    local sum_memory=0
    
    {
      echo ""
      echo "Fleet: ${fleet_name}"
      echo "Type: ${fleet_type}"
      echo "Instance Type: ${instance_type}"
      echo "Desired Capacity: ${desired_capacity}"
      echo "Running Capacity: ${running_capacity}"
      echo "Available Capacity: ${available_capacity}"
      echo "State: ${state}"
      echo "Created: ${created_time}"
      echo ""
      echo "Instance Status:"
    } >> "${OUTPUT_FILE}"
    
    while IFS= read -r instance_id; do
      if [[ -z "${instance_id}" ]]; then
        continue
      fi
      
      ((instance_count++))
      
      # Get CPU metric
      local cpu_metrics
      cpu_metrics=$(get_cloudwatch_metrics "${instance_id}" "CPUUtilization")
      local cpu_value
      cpu_value=$(echo "${cpu_metrics}" | jq -r '.Datapoints[0].Average // 0' 2>/dev/null || echo 0)
      sum_cpu=$(echo "${sum_cpu} + ${cpu_value}" | bc)
      
      # Get Memory metric
      local mem_metrics
      mem_metrics=$(get_cloudwatch_metrics "${instance_id}" "MemoryUtilization")
      local mem_value
      mem_value=$(echo "${mem_metrics}" | jq -r '.Datapoints[0].Average // 0' 2>/dev/null || echo 0)
      sum_memory=$(echo "${sum_memory} + ${mem_value}" | bc)
      
      local instance_state
      instance_state=$(echo "${instances_json}" | jq -r ".Instances[] | select(.Id == \"${instance_id}\") | .State" 2>/dev/null || echo "UNKNOWN")
      
      local status_color="${GREEN}"
      if (( $(echo "${cpu_value} > ${CPU_USAGE_WARN}" | bc -l) )); then
        status_color="${YELLOW}"
      fi
      if (( $(echo "${mem_value} > ${MEMORY_USAGE_WARN}" | bc -l) )); then
        status_color="${RED}"
      fi
      
      printf "%b  %s: CPU=%.1f%% MEM=%.1f%% State=%s%b\n" \
        "${status_color}" "${instance_id}" "${cpu_value}" "${mem_value}" "${instance_state}" "${NC}" >> "${OUTPUT_FILE}"
      
    done <<< "${fleet_instances}"
    
    # Calculate averages
    if [[ ${instance_count} -gt 0 ]]; then
      cpu_avg=$(echo "scale=2; ${sum_cpu} / ${instance_count}" | bc)
      memory_avg=$(echo "scale=2; ${sum_memory} / ${instance_count}" | bc)
    fi
    
    {
      echo ""
      echo "Average Metrics:"
      echo "  CPU Utilization: ${cpu_avg}%"
      echo "  Memory Utilization: ${memory_avg}%"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Optimization recommendations
    {
      echo "Optimization Recommendations:"
    } >> "${OUTPUT_FILE}"
    
    local recommendations_found=0
    
    # Check for underutilized capacity
    if (( $(echo "${cpu_avg} < 30" | bc -l) )); then
      {
        echo "  ⚠️  Low CPU utilization (${cpu_avg}%) - Consider reducing desired capacity"
      } >> "${OUTPUT_FILE}"
      ((recommendations_found++))
      ((optimization_opportunities++))
      
      local potential_reduction
      potential_reduction=$(echo "scale=0; ${running_capacity} * 0.3" | bc)
      potential_savings=$((potential_savings + potential_reduction))
      
      log_message WARN "Fleet ${fleet_name} has low CPU utilization"
    fi
    
    # Check for memory pressure
    if (( $(echo "${memory_avg} > ${MEMORY_USAGE_WARN}" | bc -l) )); then
      {
        echo "  ⚠️  High memory utilization (${memory_avg}%) - Consider upgrading instance type"
      } >> "${OUTPUT_FILE}"
      ((recommendations_found++))
      log_message WARN "Fleet ${fleet_name} has high memory utilization"
    fi
    
    # Check for idle capacity
    local unused_capacity
    unused_capacity=$(echo "${desired_capacity} - ${running_capacity}" | bc)
    if [[ ${unused_capacity} -gt 0 ]]; then
      {
        echo "  ℹ️  Unused capacity: ${unused_capacity} instances not running"
      } >> "${OUTPUT_FILE}"
      ((recommendations_found++))
    fi
    
    if [[ ${recommendations_found} -eq 0 ]]; then
      {
        echo "  ✓ Fleet is well-optimized"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${fleet_names}"
  
  # Summary
  {
    echo ""
    echo "=== OPTIMIZATION SUMMARY ==="
    echo "Total Fleets: ${total_fleets}"
    echo "Total Running Instances: ${total_instances}"
    echo "Optimization Opportunities: ${optimization_opportunities}"
    echo "Potential Instance Reduction: ${potential_savings}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  log_message INFO "Fleet analysis complete. Total: ${total_fleets}, Opportunities: ${optimization_opportunities}"
}

cost_optimization_analysis() {
  log_message INFO "Performing cost optimization analysis"
  
  {
    echo ""
    echo "=== COST OPTIMIZATION ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local fleets_json
  fleets_json=$(list_fleets)
  
  local fleet_names
  fleet_names=$(echo "${fleets_json}" | jq -r '.Fleets[].Name' 2>/dev/null)
  
  while IFS= read -r fleet_name; do
    local fleet_details
    fleet_details=$(describe_fleet "${fleet_name}")
    
    local instance_type
    local running_capacity
    local desired_capacity
    
    instance_type=$(echo "${fleet_details}" | jq_safe '.Fleets[0].InstanceType')
    running_capacity=$(echo "${fleet_details}" | jq_safe '.Fleets[0].RunningCapacity')
    desired_capacity=$(echo "${fleet_details}" | jq_safe '.Fleets[0].DesiredCapacity')
    
    # Estimate costs (basic pricing - adjust per region)
    local hourly_cost_per_instance
    case "${instance_type}" in
      "stream.standard.medium")    hourly_cost_per_instance=0.1 ;;
      "stream.standard.large")     hourly_cost_per_instance=0.2 ;;
      "stream.standard.xlarge")    hourly_cost_per_instance=0.4 ;;
      "stream.standard.2xlarge")   hourly_cost_per_instance=0.8 ;;
      "stream.compute.large")      hourly_cost_per_instance=0.3 ;;
      "stream.compute.xlarge")     hourly_cost_per_instance=0.6 ;;
      "stream.compute.2xlarge")    hourly_cost_per_instance=1.2 ;;
      "stream.memory.large")       hourly_cost_per_instance=0.5 ;;
      "stream.memory.xlarge")      hourly_cost_per_instance=1.0 ;;
      "stream.memory.2xlarge")     hourly_cost_per_instance=2.0 ;;
      *)                           hourly_cost_per_instance=0.2 ;;
    esac
    
    local daily_cost
    local unused_cost
    
    daily_cost=$(echo "scale=2; ${running_capacity} * ${hourly_cost_per_instance} * 24" | bc)
    unused_cost=$(echo "scale=2; (${desired_capacity} - ${running_capacity}) * ${hourly_cost_per_instance} * 24" | bc)
    
    {
      echo "Fleet: ${fleet_name}"
      echo "Instance Type: ${instance_type}"
      echo "Estimated Daily Cost: \$${daily_cost}"
      if (( $(echo "${unused_cost} > 0" | bc -l) )); then
        echo "Unused Capacity Cost: \$${unused_cost}/day"
      fi
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${fleet_names}"
}

main() {
  log_message INFO "=== AppStream 2.0 Fleet Optimizer Started ==="
  
  write_header
  analyze_fleets
  cost_optimization_analysis
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== AppStream 2.0 Fleet Optimizer Completed ==="
}

main "$@"

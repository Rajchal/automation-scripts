#!/bin/bash

################################################################################
# AWS Outposts Capacity Planner
# Analyzes Outposts resource utilization, forecasts growth, identifies
# over/under-provisioned assets, and recommends capacity adjustments.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/outposts-capacity-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/outposts-capacity.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Capacity thresholds
CPU_USAGE_HIGH="${CPU_USAGE_HIGH:-80}"           # % utilization
MEMORY_USAGE_HIGH="${MEMORY_USAGE_HIGH:-85}"     # % utilization
STORAGE_USAGE_HIGH="${STORAGE_USAGE_HIGH:-80}"   # % capacity
POWER_USAGE_HIGH="${POWER_USAGE_HIGH:-75}"       # % available
NETWORK_UTIL_HIGH="${NETWORK_UTIL_HIGH:-80}"     # % bandwidth

# Growth analysis
LOOKBACK_DAYS="${LOOKBACK_DAYS:-30}"
FORECAST_DAYS="${FORECAST_DAYS:-90}"

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

list_outposts() {
  aws outposts list-outposts \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Outposts":[]}'
}

describe_outpost() {
  local outpost_id="$1"
  aws outposts get-outpost \
    --outpost-id "${outpost_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_outpost_instances() {
  local outpost_id="$1"
  aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=outpost-id,Values=${outpost_id}" \
    --output json 2>/dev/null || echo '{"Reservations":[]}'
}

list_outpost_volumes() {
  local outpost_id="$1"
  aws ec2 describe-volumes \
    --region "${REGION}" \
    --filters "Name=outpost-id,Values=${outpost_id}" \
    --output json 2>/dev/null || echo '{"Volumes":[]}'
}

get_cw_metrics() {
  local instance_id="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name "${metric_name}" \
    --dimensions Name=InstanceId,Value="${instance_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 3600 \
    --statistics Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calc_avg_metric() {
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
      "title": "Outposts Capacity Alert",
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
    echo "AWS Outposts Capacity Planning Report"
    echo "====================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Period: Last ${LOOKBACK_DAYS} days"
    echo "Forecast Period: ${FORECAST_DAYS} days"
    echo ""
    echo "Capacity Thresholds:"
    echo "  CPU: ${CPU_USAGE_HIGH}%"
    echo "  Memory: ${MEMORY_USAGE_HIGH}%"
    echo "  Storage: ${STORAGE_USAGE_HIGH}%"
    echo "  Power: ${POWER_USAGE_HIGH}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

analyze_outposts() {
  log_message INFO "Starting Outposts capacity analysis"
  
  {
    echo "=== OUTPOSTS INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local outposts_json
  outposts_json=$(list_outposts)
  
  local outpost_ids
  outpost_ids=$(echo "${outposts_json}" | jq -r '.Outposts[]?.OutpostId' 2>/dev/null)
  
  if [[ -z "${outpost_ids}" ]]; then
    log_message WARN "No Outposts found in region ${REGION}"
    {
      echo "Status: No Outposts found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local total_outposts=0
  local total_instances=0
  local total_volume_storage=0
  local at_capacity=0
  
  while IFS= read -r outpost_id; do
    [[ -z "${outpost_id}" ]] && continue
    ((total_outposts++))
    
    log_message INFO "Analyzing Outpost: ${outpost_id}"
    
    local outpost_desc
    outpost_desc=$(describe_outpost "${outpost_id}")
    
    local outpost_name availability_zone site_id
    local hardware_gen lifecycle_status hardware_spec
    
    outpost_name=$(echo "${outpost_desc}" | jq_safe '.Outpost.OutpostName')
    availability_zone=$(echo "${outpost_desc}" | jq_safe '.Outpost.AvailabilityZone')
    site_id=$(echo "${outpost_desc}" | jq_safe '.Outpost.SiteId')
    lifecycle_status=$(echo "${outpost_desc}" | jq_safe '.Outpost.LifeCycleStatus')
    
    {
      echo "Outpost: ${outpost_name}"
      echo "ID: ${outpost_id}"
      echo "Availability Zone: ${availability_zone}"
      echo "Site ID: ${site_id}"
      printf "Lifecycle: %s\n" "${lifecycle_status}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Get instances on this Outpost
    local instances_json
    instances_json=$(list_outpost_instances "${outpost_id}")
    
    local instance_ids
    instance_ids=$(echo "${instances_json}" | jq -r '.Reservations[]?.Instances[]?.InstanceId' 2>/dev/null)
    
    local outpost_instances=0
    local total_cpu=0
    local total_memory=0
    local high_util_count=0
    
    if [[ -n "${instance_ids}" ]]; then
      {
        echo "Instances:"
      } >> "${OUTPUT_FILE}"
      
      while IFS= read -r instance_id; do
        [[ -z "${instance_id}" ]] && continue
        ((outpost_instances++))
        ((total_instances++))
        
        # Get instance type/specs
        local instance_detail
        instance_detail=$(echo "${instances_json}" | jq -r ".Reservations[].Instances[] | select(.InstanceId==\"${instance_id}\")" 2>/dev/null)
        
        local instance_type state launch_time
        instance_type=$(echo "${instance_detail}" | jq_safe '.InstanceType')
        state=$(echo "${instance_detail}" | jq_safe '.State.Name')
        launch_time=$(echo "${instance_detail}" | jq_safe '.LaunchTime')
        
        # Get CPU and memory metrics
        local cpu_json memory_json cpu_avg memory_avg
        cpu_json=$(get_cw_metrics "${instance_id}" "CPUUtilization")
        memory_json=$(get_cw_metrics "${instance_id}" "MemoryUtilization")
        
        cpu_avg=$(echo "${cpu_json}" | calc_avg_metric)
        memory_avg=$(echo "${memory_json}" | calc_avg_metric)
        
        local util_color="${GREEN}"
        if (( $(echo "${cpu_avg} > ${CPU_USAGE_HIGH} || ${memory_avg} > ${MEMORY_USAGE_HIGH}" | bc -l) )); then
          util_color="${YELLOW}"
          ((high_util_count++))
        fi
        
        printf "%b  %-15s Type: %-12s CPU: %5.1f%% Mem: %5.1f%%%b\n" \
          "${util_color}" "${instance_id}" "${instance_type}" "${cpu_avg}" "${memory_avg}" "${NC}" >> "${OUTPUT_FILE}"
        
      done <<< "${instance_ids}"
    else
      {
        echo "Instances: None"
      } >> "${OUTPUT_FILE}"
    fi
    
    # Get volumes on this Outpost
    local volumes_json
    volumes_json=$(list_outpost_volumes "${outpost_id}")
    
    local volume_ids
    volume_ids=$(echo "${volumes_json}" | jq -r '.Volumes[]?.VolumeId' 2>/dev/null)
    
    local total_volumes=0
    local total_volume_size=0
    
    if [[ -n "${volume_ids}" ]]; then
      {
        echo ""
        echo "Storage Volumes:"
      } >> "${OUTPUT_FILE}"
      
      while IFS= read -r volume_id; do
        [[ -z "${volume_id}" ]] && continue
        ((total_volumes++))
        
        local vol_size vol_type state iops
        vol_size=$(echo "${volumes_json}" | jq -r ".Volumes[] | select(.VolumeId==\"${volume_id}\") | .Size" 2>/dev/null || echo 0)
        vol_type=$(echo "${volumes_json}" | jq -r ".Volumes[] | select(.VolumeId==\"${volume_id}\") | .VolumeType" 2>/dev/null || echo "unknown")
        state=$(echo "${volumes_json}" | jq -r ".Volumes[] | select(.VolumeId==\"${volume_id}\") | .State" 2>/dev/null || echo "unknown")
        iops=$(echo "${volumes_json}" | jq -r ".Volumes[] | select(.VolumeId==\"${volume_id}\") | .Iops" 2>/dev/null || echo 0)
        
        total_volume_size=$((total_volume_size + vol_size))
        total_volume_storage=$((total_volume_storage + vol_size))
        
        printf "  %-20s %5d GB %s (${state}) IOPS: %d\n" "${volume_id}" "${vol_size}" "${vol_type}" "${iops}" >> "${OUTPUT_FILE}"
        
      done <<< "${volume_ids}"
    else
      {
        echo ""
        echo "Storage Volumes: None"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
      echo "Capacity Summary:"
      echo "  Total Instances: ${outpost_instances}"
      echo "  High Utilization: ${high_util_count}"
      echo "  Total Storage: ${total_volume_size} GB"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Recommendations for this Outpost
    if [[ ${high_util_count} -gt 0 ]]; then
      ((at_capacity++))
      {
        echo "Capacity Concerns:"
        echo "  ⚠️  ${high_util_count} instance(s) experiencing high CPU/memory utilization"
        echo "  Recommendation: Consider adding compute capacity"
      } >> "${OUTPUT_FILE}"
      
      log_message WARN "Outpost ${outpost_id} has ${high_util_count} high-utilization instances"
      local alert_msg="⚠️  Outpost ${outpost_name}: ${high_util_count} instances at high utilization"
      send_slack_alert "${alert_msg}" "WARNING"
    fi
    
    {
      echo ""
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${outpost_ids}"
  
  # Overall summary
  {
    echo ""
    echo "=== OVERALL CAPACITY SUMMARY ==="
    echo "Total Outposts: ${total_outposts}"
    echo "Total Instances: ${total_instances}"
    echo "Total Storage: ${total_volume_storage} GB"
    echo "Outposts at Capacity: ${at_capacity}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

forecast_growth() {
  log_message INFO "Forecasting capacity growth"
  
  {
    echo ""
    echo "=== CAPACITY FORECAST ==="
    echo ""
    echo "Based on ${LOOKBACK_DAYS}-day historical trends:"
    echo ""
    echo "Growth Projections (${FORECAST_DAYS}-day forecast):"
    echo "  • Instance count: Monitor for seasonal patterns"
    echo "  • Storage growth: Analyze volume allocation trends"
    echo "  • Utilization patterns: Peak vs baseline comparisons"
    echo ""
    echo "Capacity Planning Recommendations:"
    echo "  1. If >80% CPU/Memory: Plan to add compute capacity within 30 days"
    echo "  2. If >80% Storage: Expand storage shelf within 60 days"
    echo "  3. Monitor power consumption trends"
    echo "  4. Review network bandwidth requirements"
    echo "  5. Consider mixed instance types for optimal utilization"
    echo ""
  } >> "${OUTPUT_FILE}"
}

power_and_cooling() {
  {
    echo "=== POWER & COOLING ANALYSIS ==="
    echo ""
    echo "Power Capacity Planning:"
    echo "  • Monitor power distribution unit (PDU) utilization"
    echo "  • Plan for 10-15% overhead capacity"
    echo "  • Consider backup power requirements"
    echo "  • Verify cooling capacity matches heat dissipation"
    echo ""
    echo "Network Connectivity:"
    echo "  • Monitor uplink saturation"
    echo "  • Plan for local redundancy"
    echo "  • Consider AWS Outposts Direct Connect connectivity"
    echo "  • Plan for growth in data transfer rates"
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo ""
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    echo "Compute Optimization:"
    echo "  • Right-size instances based on actual utilization"
    echo "  • Use AWS Compute Optimizer for recommendations"
    echo "  • Consider auto-scaling for variable workloads"
    echo "  • Implement workload consolidation"
    echo ""
    echo "Storage Optimization:"
    echo "  • Archive inactive snapshots"
    echo "  • Implement lifecycle policies"
    echo "  • Monitor volume fragmentation"
    echo "  • Consider EBS gp3 for better price/performance"
    echo ""
    echo "Network Optimization:"
    echo "  • Monitor and optimize data transfer patterns"
    echo "  • Implement local caching for frequently accessed data"
    echo "  • Use placement groups for low-latency communication"
    echo ""
    echo "Cost Optimization:"
    echo "  • Track Outposts capacity utilization"
    echo "  • Plan for efficient use of purchased capacity"
    echo "  • Review reserved capacity vs on-demand usage"
    echo "  • Optimize instance types based on workload profiles"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Outposts Capacity Planner Started ==="
  
  write_header
  analyze_outposts
  forecast_growth
  power_and_cooling
  optimization_recommendations
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "Next Steps:"
    echo "  1. Review high-utilization instances"
    echo "  2. Forecast capacity needs for next quarter"
    echo "  3. Plan for expansion if approaching limits"
    echo "  4. Optimize underutilized resources"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Outposts Capacity Planner Completed ==="
}

main "$@"

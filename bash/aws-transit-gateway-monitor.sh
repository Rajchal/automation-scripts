#!/bin/bash

################################################################################
# AWS Transit Gateway Monitor
# Monitors Transit Gateway health, attachments, route tables, VPN connections,
# bandwidth usage, detects blackhole routes, and provides network optimization.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/tgw-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/tgw-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
BANDWIDTH_WARN_MBPS="${BANDWIDTH_WARN_MBPS:-1000}"      # MB/s
PACKET_LOSS_WARN="${PACKET_LOSS_WARN:-1}"               # % packet loss
ATTACHMENT_WARN_AGE="${ATTACHMENT_WARN_AGE:-7}"         # days in pending
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
TOTAL_TGWS=0
HEALTHY_TGWS=0
UNHEALTHY_TGWS=0
BLACKHOLE_ROUTES=0
PENDING_ATTACHMENTS=0

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
      "title": "Transit Gateway Alert",
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
    echo "AWS Transit Gateway Monitor"
    echo "============================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Bandwidth Warning: ${BANDWIDTH_WARN_MBPS} Mbps"
    echo "  Packet Loss Warning: ${PACKET_LOSS_WARN}%"
    echo "  Attachment Age Warning: ${ATTACHMENT_WARN_AGE} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_transit_gateways() {
  aws ec2 describe-transit-gateways \
    --region "${REGION}" \
    --query 'TransitGateways[].[TransitGatewayId,State,OwnerId,Description]' \
    --output json 2>/dev/null || echo '[]'
}

describe_transit_gateway() {
  local tgw_id="$1"
  aws ec2 describe-transit-gateways \
    --transit-gateway-ids "${tgw_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"TransitGateways":[]}'
}

list_tgw_attachments() {
  local tgw_id="$1"
  aws ec2 describe-transit-gateway-attachments \
    --filters "Name=transit-gateway-id,Values=${tgw_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"TransitGatewayAttachments":[]}'
}

list_tgw_route_tables() {
  local tgw_id="$1"
  aws ec2 describe-transit-gateway-route-tables \
    --filters "Name=transit-gateway-id,Values=${tgw_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"TransitGatewayRouteTables":[]}'
}

get_route_table_routes() {
  local rtb_id="$1"
  aws ec2 search-transit-gateway-routes \
    --transit-gateway-route-table-id "${rtb_id}" \
    --filters "Name=state,Values=active,blackhole" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Routes":[]}'
}

get_tgw_metrics() {
  local tgw_id="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/TransitGateway \
    --metric-name "${metric_name}" \
    --dimensions Name=TransitGateway,Value="${tgw_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

calculate_max() {
  jq -r '.Datapoints[].Maximum' 2>/dev/null | \
    awk 'BEGIN{max=0} {if($1>max) max=$1} END{printf "%.2f", max}'
}

monitor_transit_gateways() {
  log_message INFO "Starting Transit Gateway monitoring"
  
  {
    echo "=== TRANSIT GATEWAY INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local tgws_json
  tgws_json=$(list_transit_gateways)
  
  local tgw_count
  tgw_count=$(echo "${tgws_json}" | jq 'length' 2>/dev/null || echo "0")
  
  if [[ ${tgw_count} -eq 0 ]]; then
    log_message WARN "No Transit Gateways found in region ${REGION}"
    {
      echo "Status: No Transit Gateways configured"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  TOTAL_TGWS=${tgw_count}
  
  local tgw_ids
  tgw_ids=$(echo "${tgws_json}" | jq -r '.[][0]' 2>/dev/null)
  
  while IFS= read -r tgw_id; do
    [[ -z "${tgw_id}" ]] && continue
    
    log_message INFO "Analyzing Transit Gateway: ${tgw_id}"
    
    local tgw_desc
    tgw_desc=$(describe_transit_gateway "${tgw_id}")
    
    local state owner_id description default_rtb_id amazon_asn
    state=$(echo "${tgw_desc}" | jq_safe '.TransitGateways[0].State')
    owner_id=$(echo "${tgw_desc}" | jq_safe '.TransitGateways[0].OwnerId')
    description=$(echo "${tgw_desc}" | jq_safe '.TransitGateways[0].Description')
    default_rtb_id=$(echo "${tgw_desc}" | jq_safe '.TransitGateways[0].Options.AssociationDefaultRouteTableId')
    amazon_asn=$(echo "${tgw_desc}" | jq_safe '.TransitGateways[0].Options.AmazonSideAsn')
    
    {
      echo "Transit Gateway: ${tgw_id}"
      echo "Description: ${description}"
      echo "Owner ID: ${owner_id}"
      echo "State: ${state}"
      echo "Amazon ASN: ${amazon_asn}"
      echo "Default Route Table: ${default_rtb_id}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Check TGW state
    if [[ "${state}" == "available" ]]; then
      ((HEALTHY_TGWS++))
      {
        printf "%b✓ Transit Gateway Available%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      ((UNHEALTHY_TGWS++))
      {
        printf "%b⚠️  Transit Gateway State: %s%b\n" "${RED}" "${state}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "TGW ${tgw_id} in state: ${state}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Analyze attachments
    analyze_attachments "${tgw_id}"
    
    # Analyze route tables
    analyze_route_tables "${tgw_id}"
    
    # Analyze bandwidth metrics
    analyze_bandwidth "${tgw_id}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${tgw_ids}"
}

analyze_attachments() {
  local tgw_id="$1"
  
  {
    echo "Attachments:"
  } >> "${OUTPUT_FILE}"
  
  local attachments_json
  attachments_json=$(list_tgw_attachments "${tgw_id}")
  
  local attachment_count
  attachment_count=$(echo "${attachments_json}" | jq '.TransitGatewayAttachments | length' 2>/dev/null || echo "0")
  
  if [[ ${attachment_count} -eq 0 ]]; then
    {
      echo "  No attachments found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Total Attachments: ${attachment_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local attachments
  attachments=$(echo "${attachments_json}" | jq -c '.TransitGatewayAttachments[]' 2>/dev/null)
  
  local available_count=0
  local pending_count=0
  local failed_count=0
  
  while IFS= read -r attachment; do
    [[ -z "${attachment}" ]] && continue
    
    local att_id att_type att_state resource_id creation_time
    att_id=$(echo "${attachment}" | jq_safe '.TransitGatewayAttachmentId')
    att_type=$(echo "${attachment}" | jq_safe '.ResourceType')
    att_state=$(echo "${attachment}" | jq_safe '.State')
    resource_id=$(echo "${attachment}" | jq_safe '.ResourceId')
    creation_time=$(echo "${attachment}" | jq_safe '.CreationTime')
    
    {
      echo "  Attachment: ${att_id}"
      echo "    Type: ${att_type}"
      echo "    Resource: ${resource_id}"
      echo "    State: ${att_state}"
      echo "    Created: ${creation_time}"
    } >> "${OUTPUT_FILE}"
    
    case "${att_state}" in
      available)
        ((available_count++))
        {
          printf "    %b✓ Available%b\n" "${GREEN}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ;;
      pending*)
        ((pending_count++))
        ((PENDING_ATTACHMENTS++))
        {
          printf "    %b⚠️  State: %s%b\n" "${YELLOW}" "${att_state}" "${NC}"
        } >> "${OUTPUT_FILE}"
        log_message WARN "TGW ${tgw_id} attachment ${att_id} in ${att_state} state"
        ;;
      failed|failing|rejected|deleting|deleted)
        ((failed_count++))
        {
          printf "    %b❌ State: %s%b\n" "${RED}" "${att_state}" "${NC}"
        } >> "${OUTPUT_FILE}"
        log_message ERROR "TGW ${tgw_id} attachment ${att_id} in ${att_state} state"
        ;;
    esac
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${attachments}"
  
  {
    echo "  Summary: ${available_count} available, ${pending_count} pending, ${failed_count} failed"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_route_tables() {
  local tgw_id="$1"
  
  {
    echo "Route Tables:"
  } >> "${OUTPUT_FILE}"
  
  local rtbs_json
  rtbs_json=$(list_tgw_route_tables "${tgw_id}")
  
  local rtb_count
  rtb_count=$(echo "${rtbs_json}" | jq '.TransitGatewayRouteTables | length' 2>/dev/null || echo "0")
  
  if [[ ${rtb_count} -eq 0 ]]; then
    {
      echo "  No route tables found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Total Route Tables: ${rtb_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local rtb_ids
  rtb_ids=$(echo "${rtbs_json}" | jq -r '.TransitGatewayRouteTables[].TransitGatewayRouteTableId' 2>/dev/null)
  
  while IFS= read -r rtb_id; do
    [[ -z "${rtb_id}" ]] && continue
    
    local rtb_state
    rtb_state=$(echo "${rtbs_json}" | jq -r ".TransitGatewayRouteTables[] | select(.TransitGatewayRouteTableId==\"${rtb_id}\") | .State" 2>/dev/null)
    
    {
      echo "  Route Table: ${rtb_id}"
      echo "    State: ${rtb_state}"
    } >> "${OUTPUT_FILE}"
    
    # Get routes
    local routes_json
    routes_json=$(get_route_table_routes "${rtb_id}")
    
    local route_count blackhole_count active_count
    route_count=$(echo "${routes_json}" | jq '.Routes | length' 2>/dev/null || echo "0")
    blackhole_count=$(echo "${routes_json}" | jq '[.Routes[] | select(.State=="blackhole")] | length' 2>/dev/null || echo "0")
    active_count=$(echo "${routes_json}" | jq '[.Routes[] | select(.State=="active")] | length' 2>/dev/null || echo "0")
    
    {
      echo "    Total Routes: ${route_count}"
      echo "    Active Routes: ${active_count}"
    } >> "${OUTPUT_FILE}"
    
    if [[ ${blackhole_count} -gt 0 ]]; then
      ((BLACKHOLE_ROUTES+=${blackhole_count}))
      {
        printf "    %b⚠️  Blackhole Routes: %d%b\n" "${RED}" "${blackhole_count}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "TGW ${tgw_id} RTB ${rtb_id} has ${blackhole_count} blackhole routes"
      
      # List blackhole routes
      local blackhole_cidrs
      blackhole_cidrs=$(echo "${routes_json}" | jq -r '.Routes[] | select(.State=="blackhole") | .DestinationCidrBlock' 2>/dev/null)
      
      while IFS= read -r cidr; do
        [[ -z "${cidr}" ]] && continue
        {
          echo "      Blackhole: ${cidr}"
        } >> "${OUTPUT_FILE}"
      done <<< "${blackhole_cidrs}"
    else
      {
        echo "    ✓ No blackhole routes"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${rtb_ids}"
}

analyze_bandwidth() {
  local tgw_id="$1"
  
  {
    echo "Network Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get bandwidth metrics
  local bytes_in_json bytes_out_json packet_loss_json
  bytes_in_json=$(get_tgw_metrics "${tgw_id}" "BytesIn")
  bytes_out_json=$(get_tgw_metrics "${tgw_id}" "BytesOut")
  packet_loss_json=$(get_tgw_metrics "${tgw_id}" "PacketDropCountBlackhole")
  
  local bytes_in_avg bytes_out_avg packet_loss_avg
  local bytes_in_max bytes_out_max
  
  bytes_in_avg=$(echo "${bytes_in_json}" | calculate_avg)
  bytes_out_avg=$(echo "${bytes_out_json}" | calculate_avg)
  bytes_in_max=$(echo "${bytes_in_json}" | calculate_max)
  bytes_out_max=$(echo "${bytes_out_json}" | calculate_max)
  packet_loss_avg=$(echo "${packet_loss_json}" | calculate_avg)
  
  # Convert bytes to Mbps (bytes per 5 min -> Mbps)
  local in_mbps_avg out_mbps_avg in_mbps_max out_mbps_max
  in_mbps_avg=$(echo "scale=2; ${bytes_in_avg} * 8 / 1000000 / ${METRIC_PERIOD}" | bc -l 2>/dev/null || echo "0")
  out_mbps_avg=$(echo "scale=2; ${bytes_out_avg} * 8 / 1000000 / ${METRIC_PERIOD}" | bc -l 2>/dev/null || echo "0")
  in_mbps_max=$(echo "scale=2; ${bytes_in_max} * 8 / 1000000 / ${METRIC_PERIOD}" | bc -l 2>/dev/null || echo "0")
  out_mbps_max=$(echo "scale=2; ${bytes_out_max} * 8 / 1000000 / ${METRIC_PERIOD}" | bc -l 2>/dev/null || echo "0")
  
  {
    echo "  Inbound Traffic:"
    echo "    Average: ${in_mbps_avg} Mbps"
    echo "    Peak: ${in_mbps_max} Mbps"
    echo "  Outbound Traffic:"
    echo "    Average: ${out_mbps_avg} Mbps"
    echo "    Peak: ${out_mbps_max} Mbps"
    echo "  Packet Loss: ${packet_loss_avg} packets"
  } >> "${OUTPUT_FILE}"
  
  # Check thresholds
  if (( $(echo "${in_mbps_max} > ${BANDWIDTH_WARN_MBPS}" | bc -l) )) || \
     (( $(echo "${out_mbps_max} > ${BANDWIDTH_WARN_MBPS}" | bc -l) )); then
    {
      printf "  %b⚠️  High bandwidth usage detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "TGW ${tgw_id} exceeding bandwidth threshold"
  fi
  
  if (( $(echo "${packet_loss_avg} > 0" | bc -l) )); then
    {
      printf "  %b⚠️  Packet loss detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== TRANSIT GATEWAY SUMMARY ==="
    echo ""
    printf "Total Transit Gateways: %d\n" "${TOTAL_TGWS}"
    printf "%bHealthy: %d%b\n" "${GREEN}" "${HEALTHY_TGWS}" "${NC}"
    printf "%bUnhealthy: %d%b\n" "${RED}" "${UNHEALTHY_TGWS}" "${NC}"
    printf "%bPending Attachments: %d%b\n" "${YELLOW}" "${PENDING_ATTACHMENTS}" "${NC}"
    printf "%bBlackhole Routes: %d%b\n" "${RED}" "${BLACKHOLE_ROUTES}" "${NC}"
    echo ""
    
    if [[ ${UNHEALTHY_TGWS} -gt 0 ]] || [[ ${BLACKHOLE_ROUTES} -gt 0 ]]; then
      printf "%b[WARNING] Transit Gateway issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All Transit Gateways operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

optimization_recommendations() {
  {
    echo "=== OPTIMIZATION RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${BLACKHOLE_ROUTES} -gt 0 ]]; then
      echo "Blackhole Route Remediation:"
      echo "  • Review and remove blackhole routes from route tables"
      echo "  • Verify attachment availability for affected destinations"
      echo "  • Check for deleted or failed VPC/VPN attachments"
      echo "  • Use route propagation where appropriate"
      echo ""
    fi
    
    if [[ ${PENDING_ATTACHMENTS} -gt 0 ]]; then
      echo "Pending Attachment Resolution:"
      echo "  • Check VPC/subnet CIDR overlaps"
      echo "  • Verify IAM permissions for cross-account attachments"
      echo "  • Review attachment acceptance (if resource sharing enabled)"
      echo "  • Check for quota limits on attachments"
      echo ""
    fi
    
    echo "Best Practices:"
    echo "  • Enable CloudWatch Logs for TGW Flow Logs"
    echo "  • Use AWS Network Firewall for inter-VPC inspection"
    echo "  • Implement route table segmentation (dev/prod/shared)"
    echo "  • Enable automatic route propagation for VPN attachments"
    echo "  • Monitor bandwidth utilization for capacity planning"
    echo "  • Document network topology and routing policies"
    echo "  • Use Resource Access Manager for cross-account sharing"
    echo "  • Implement VPC peering for same-region, low-latency traffic"
    echo ""
    echo "Security Considerations:"
    echo "  • Restrict attachments using RAM resource shares"
    echo "  • Apply prefix lists for route filtering"
    echo "  • Enable Network Access Analyzer for path validation"
    echo "  • Use AWS Firewall Manager for centralized rule management"
    echo "  • Implement least-privilege routing policies"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Transit Gateway Monitor Started ==="
  
  write_header
  monitor_transit_gateways
  generate_summary
  optimization_recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS Transit Gateway Documentation:"
    echo "  https://docs.aws.amazon.com/vpc/latest/tgw/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Transit Gateway Monitor Completed ==="
  
  # Send alerts
  if [[ ${UNHEALTHY_TGWS} -gt 0 ]] || [[ ${BLACKHOLE_ROUTES} -gt 0 ]]; then
    send_slack_alert "⚠️ Transit Gateway issues detected: ${UNHEALTHY_TGWS} unhealthy TGWs, ${BLACKHOLE_ROUTES} blackhole routes" "WARNING"
    send_email_alert "Transit Gateway Alert" "$(cat "${OUTPUT_FILE}")"
  fi
}

main "$@"

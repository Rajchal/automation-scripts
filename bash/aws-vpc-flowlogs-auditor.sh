#!/bin/bash

################################################################################
# AWS VPC Flow Logs Auditor
# Audits VPC Flow Logs coverage across VPCs, subnets, and ENIs
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/vpc-flowlogs-audit-$(date +%s).txt"
LOG_FILE="/var/log/vpc-flowlogs-audit.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_vpcs() {
  aws ec2 describe-vpcs \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_subnets() {
  aws ec2 describe-subnets \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_flow_logs() {
  aws ec2 describe-flow-logs \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_enis() {
  aws ec2 describe-network-interfaces \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS VPC Flow Logs Coverage Audit Report"
    echo "========================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_vpcs() {
  log_message INFO "Auditing VPC Flow Logs coverage"
  {
    echo "=== VPC FLOW LOGS COVERAGE ==="
  } >> "${OUTPUT_FILE}"

  local total_vpcs=0 vpcs_with_logs=0 vpcs_without_logs=0

  local vpcs_json flow_logs_json
  vpcs_json=$(list_vpcs)
  flow_logs_json=$(list_flow_logs)

  echo "${vpcs_json}" | jq -c '.Vpcs[]?' 2>/dev/null | while read -r vpc; do
    ((total_vpcs++))
    local vpc_id cidr is_default state tags name
    vpc_id=$(echo "${vpc}" | jq_safe '.VpcId')
    cidr=$(echo "${vpc}" | jq_safe '.CidrBlock')
    is_default=$(echo "${vpc}" | jq_safe '.IsDefault')
    state=$(echo "${vpc}" | jq_safe '.State')
    tags=$(echo "${vpc}" | jq_safe '.Tags')
    name=$(echo "${tags}" | jq -r '.[] | select(.Key=="Name") | .Value' 2>/dev/null || echo "")

    {
      echo "VPC: ${vpc_id}"
      echo "  Name: ${name}"
      echo "  CIDR: ${cidr}"
      echo "  Default: ${is_default}"
      echo "  State: ${state}"
    } >> "${OUTPUT_FILE}"

    # Check if VPC has flow logs
    local flow_logs
    flow_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${vpc_id}\")" 2>/dev/null)

    if [[ -z "${flow_logs}" ]]; then
      ((vpcs_without_logs++))
      echo "  Flow Logs: DISABLED" >> "${OUTPUT_FILE}"
      echo "  WARNING: VPC has no flow logs enabled" >> "${OUTPUT_FILE}"
    else
      ((vpcs_with_logs++))
      echo "  Flow Logs: ENABLED" >> "${OUTPUT_FILE}"
      
      # List flow log details
      echo "${flow_logs}" | while read -r log; do
        local log_id log_dest log_status traffic_type log_format
        log_id=$(echo "${log}" | jq_safe '.FlowLogId')
        log_dest=$(echo "${log}" | jq_safe '.LogDestination')
        log_status=$(echo "${log}" | jq_safe '.FlowLogStatus')
        traffic_type=$(echo "${log}" | jq_safe '.TrafficType')
        log_format=$(echo "${log}" | jq_safe '.LogFormat')

        {
          echo "    Log ID: ${log_id}"
          echo "    Status: ${log_status}"
          echo "    Traffic Type: ${traffic_type}"
          echo "    Destination: ${log_dest}"
        } >> "${OUTPUT_FILE}"

        if [[ "${log_status}" != "ACTIVE" ]]; then
          echo "    WARNING: Flow log status is ${log_status}" >> "${OUTPUT_FILE}"
        fi
      done
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "VPC Summary:"
    echo "  Total VPCs: ${total_vpcs}"
    echo "  With Flow Logs: ${vpcs_with_logs}"
    echo "  Without Flow Logs: ${vpcs_without_logs}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_subnets() {
  log_message INFO "Auditing Subnet Flow Logs coverage"
  {
    echo "=== SUBNET FLOW LOGS COVERAGE ==="
  } >> "${OUTPUT_FILE}"

  local total_subnets=0 subnets_with_logs=0 subnets_without_logs=0

  local subnets_json flow_logs_json
  subnets_json=$(list_subnets)
  flow_logs_json=$(list_flow_logs)

  echo "${subnets_json}" | jq -c '.Subnets[]?' 2>/dev/null | while read -r subnet; do
    ((total_subnets++))
    local subnet_id vpc_id az cidr available_ips tags name
    subnet_id=$(echo "${subnet}" | jq_safe '.SubnetId')
    vpc_id=$(echo "${subnet}" | jq_safe '.VpcId')
    az=$(echo "${subnet}" | jq_safe '.AvailabilityZone')
    cidr=$(echo "${subnet}" | jq_safe '.CidrBlock')
    available_ips=$(echo "${subnet}" | jq_safe '.AvailableIpAddressCount')
    tags=$(echo "${subnet}" | jq_safe '.Tags')
    name=$(echo "${tags}" | jq -r '.[] | select(.Key=="Name") | .Value' 2>/dev/null || echo "")

    # Check if subnet or its VPC has flow logs
    local subnet_logs vpc_logs
    subnet_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${subnet_id}\")" 2>/dev/null)
    vpc_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${vpc_id}\")" 2>/dev/null)

    if [[ -n "${subnet_logs}" || -n "${vpc_logs}" ]]; then
      ((subnets_with_logs++))
    else
      ((subnets_without_logs++))
      {
        echo "Subnet: ${subnet_id}"
        echo "  Name: ${name}"
        echo "  VPC: ${vpc_id}"
        echo "  AZ: ${az}"
        echo "  CIDR: ${cidr}"
        echo "  Available IPs: ${available_ips}"
        echo "  WARNING: No flow logs (subnet or VPC level)"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Subnet Summary:"
    echo "  Total Subnets: ${total_subnets}"
    echo "  With Coverage: ${subnets_with_logs}"
    echo "  Without Coverage: ${subnets_without_logs}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_flow_log_destinations() {
  log_message INFO "Analyzing Flow Log destinations"
  {
    echo "=== FLOW LOG DESTINATIONS ==="
  } >> "${OUTPUT_FILE}"

  local s3_count=0 cw_logs_count=0 kinesis_count=0

  local flow_logs_json
  flow_logs_json=$(list_flow_logs)

  echo "${flow_logs_json}" | jq -c '.FlowLogs[]?' 2>/dev/null | while read -r log; do
    local dest_type log_dest resource_id
    dest_type=$(echo "${log}" | jq_safe '.LogDestinationType')
    log_dest=$(echo "${log}" | jq_safe '.LogDestination')
    resource_id=$(echo "${log}" | jq_safe '.ResourceId')

    case "${dest_type}" in
      "s3") ((s3_count++)) ;;
      "cloud-watch-logs") ((cw_logs_count++)) ;;
      "kinesis-data-firehose") ((kinesis_count++)) ;;
    esac
  done

  {
    echo "Destination Summary:"
    echo "  S3 Buckets: ${s3_count}"
    echo "  CloudWatch Logs: ${cw_logs_count}"
    echo "  Kinesis Firehose: ${kinesis_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_eni_coverage() {
  log_message INFO "Checking ENI flow log coverage"
  {
    echo "=== NETWORK INTERFACE COVERAGE ==="
  } >> "${OUTPUT_FILE}"

  local total_enis=0 enis_covered=0 enis_not_covered=0

  local enis_json flow_logs_json
  enis_json=$(list_enis)
  flow_logs_json=$(list_flow_logs)

  echo "${enis_json}" | jq -c '.NetworkInterfaces[]?' 2>/dev/null | head -50 | while read -r eni; do
    ((total_enis++))
    local eni_id vpc_id subnet_id status interface_type
    eni_id=$(echo "${eni}" | jq_safe '.NetworkInterfaceId')
    vpc_id=$(echo "${eni}" | jq_safe '.VpcId')
    subnet_id=$(echo "${eni}" | jq_safe '.SubnetId')
    status=$(echo "${eni}" | jq_safe '.Status')
    interface_type=$(echo "${eni}" | jq_safe '.InterfaceType')

    # Check if ENI, subnet, or VPC has flow logs
    local eni_logs subnet_logs vpc_logs
    eni_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${eni_id}\")" 2>/dev/null)
    subnet_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${subnet_id}\")" 2>/dev/null)
    vpc_logs=$(echo "${flow_logs_json}" | jq -c ".FlowLogs[] | select(.ResourceId==\"${vpc_id}\")" 2>/dev/null)

    if [[ -n "${eni_logs}" || -n "${subnet_logs}" || -n "${vpc_logs}" ]]; then
      ((enis_covered++))
    else
      ((enis_not_covered++))
    fi
  done

  {
    echo "ENI Summary (sample of 50):"
    echo "  Total Sampled: ${total_enis}"
    echo "  With Coverage: ${enis_covered}"
    echo "  Without Coverage: ${enis_not_covered}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_inactive_flow_logs() {
  log_message INFO "Checking for inactive flow logs"
  {
    echo "=== INACTIVE FLOW LOGS ==="
  } >> "${OUTPUT_FILE}"

  local inactive_count=0

  local flow_logs_json
  flow_logs_json=$(list_flow_logs)

  echo "${flow_logs_json}" | jq -c '.FlowLogs[]?' 2>/dev/null | while read -r log; do
    local log_id status resource_id
    log_id=$(echo "${log}" | jq_safe '.FlowLogId')
    status=$(echo "${log}" | jq_safe '.FlowLogStatus')
    resource_id=$(echo "${log}" | jq_safe '.ResourceId')

    if [[ "${status}" != "ACTIVE" ]]; then
      ((inactive_count++))
      {
        echo "Flow Log: ${log_id}"
        echo "  Resource: ${resource_id}"
        echo "  Status: ${status}"
        echo "  WARNING: Flow log is not active"
        echo ""
      } >> "${OUTPUT_FILE}"
    fi
  done

  {
    echo "Inactive Flow Logs: ${inactive_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total_vpcs="$1"; local vpcs_no_logs="$2"; local subnets_no_logs="$3"; local inactive="$4"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS VPC Flow Logs Audit Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Total VPCs", "value": "${total_vpcs}", "short": true},
        {"title": "VPCs Without Logs", "value": "${vpcs_no_logs}", "short": true},
        {"title": "Subnets Without Coverage", "value": "${subnets_no_logs}", "short": true},
        {"title": "Inactive Flow Logs", "value": "${inactive}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting AWS VPC Flow Logs audit"
  write_header
  report_vpcs
  report_subnets
  report_flow_log_destinations
  report_eni_coverage
  report_inactive_flow_logs
  log_message INFO "Audit complete. Report saved to: ${OUTPUT_FILE}"

  local total_vpcs vpcs_no_logs subnets_no_logs inactive
  total_vpcs=$(grep -c "^VPC: vpc-" "${OUTPUT_FILE}" || echo 0)
  vpcs_no_logs=$(grep -c "VPC has no flow logs" "${OUTPUT_FILE}" || echo 0)
  subnets_no_logs=$(grep "Without Coverage:" "${OUTPUT_FILE}" | grep "Subnet" | awk '{print $NF}' || echo 0)
  inactive=$(grep -c "Flow log is not active" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${total_vpcs}" "${vpcs_no_logs}" "${subnets_no_logs}" "${inactive}"
  cat "${OUTPUT_FILE}"
}

main "$@"

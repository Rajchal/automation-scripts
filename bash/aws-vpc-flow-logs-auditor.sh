#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-vpc-flow-logs-auditor.log"
REPORT_FILE="/tmp/vpc-flow-logs-auditor-$(date +%Y%m%d%H%M%S).txt"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
REGION="${AWS_REGION:-${REGION:-us-east-1}}"

log_message() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$LOG_FILE"; }

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "AWS VPC Flow Logs Auditor Report - $(date -u)" > "$REPORT_FILE"
  echo "Region (API): $REGION" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

check_vpc() {
  local vpc_id="$1"
  local cidr="$2"
  echo "VPC: $vpc_id CIDR: $cidr" >> "$REPORT_FILE"

  # find flow logs for this VPC
  fjson=$(aws ec2 describe-flow-logs --filter Name=resource-id,Values="$vpc_id" --output json 2>/dev/null || echo '{"FlowLogs":[]}')
  count=$(echo "$fjson" | jq -r '.FlowLogs | length')

  if [ "$count" -eq 0 ]; then
    echo "  NO_FLOW_LOGS" >> "$REPORT_FILE"
    send_slack_alert "VPC FlowLogs Alert: VPC $vpc_id has no flow logs configured"
  else
    echo "  FlowLogs found: $count" >> "$REPORT_FILE"
    echo "$fjson" | jq -c '.FlowLogs[]' | while read -r fl; do
      status=$(echo "$fl" | jq -r '.FlowLogStatus // empty')
      destination_type=$(echo "$fl" | jq -r '.DestinationType // empty')
      dest=$(echo "$fl" | jq -r '.LogDestination // empty')
      traffic_type=$(echo "$fl" | jq -r '.TrafficType // empty')
      max_aggregation=$(echo "$fl" | jq -r '.MaxAggregationInterval // empty')

      echo "    status=$status type=$destination_type dest=$dest traffic=$traffic_type interval=$max_aggregation" >> "$REPORT_FILE"

      if [ "$status" != "ACTIVE" ]; then
        echo "    FLOW_LOG_NOT_ACTIVE" >> "$REPORT_FILE"
        send_slack_alert "VPC FlowLogs Alert: Flow log for VPC $vpc_id is not active (status=$status)"
      fi

      if [ -z "$dest" ] || [ "$dest" = "null" ]; then
        echo "    NO_DESTINATION" >> "$REPORT_FILE"
        send_slack_alert "VPC FlowLogs Alert: Flow log for VPC $vpc_id has no destination"
      fi
    done
  fi

  echo "" >> "$REPORT_FILE"
}

main() {
  write_header

  aws ec2 describe-vpcs --output json 2>/dev/null | jq -c '.Vpcs[]? // empty' | while read -r v; do
    vid=$(echo "$v" | jq -r '.VpcId')
    cidr=$(echo "$v" | jq -r '.CidrBlock // empty')
    check_vpc "$vid" "$cidr"
  done

  log_message "VPC Flow Logs audit written to $REPORT_FILE"
}

main "$@"

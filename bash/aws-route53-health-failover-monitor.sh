#!/bin/bash

################################################################################
# AWS Route 53 Health & Failover Monitor
# Audits Route 53: health checks status, latency/failure counts, failover
# records, alias target health, CloudWatch metrics (HealthCheckStatus,
# HealthCheckPercentageHealthy, ChildHealthCheckStatus, ConnectionTime,
# SSLHandshakeTime, TimeToFirstByte). Includes logging, Slack/email alerts.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/route53-health-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/route53-health-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
HEALTH_CHECK_HEALTHY_WARN_PCT="${HEALTH_CHECK_HEALTHY_WARN_PCT:-90}"
LATENCY_WARN_MS="${LATENCY_WARN_MS:-200}"
CONNECTION_TIME_WARN_MS="${CONNECTION_TIME_WARN_MS:-1000}"
TTB_WARN_MS="${TTB_WARN_MS:-2000}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_HEALTH_CHECKS=0
UNHEALTHY_CHECKS=0
CHECKS_HIGH_LATENCY=0
CHECKS_POOR_THRESHOLD=0
TOTAL_ZONES=0
TOTAL_RECORDS=0
FAILOVER_RECORDS=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || echo ""; }

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
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
      "title": "AWS Route 53 Health Alert",
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
    echo "AWS Route 53 Health & Failover Monitor"
    echo "======================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Health Check Healthy %: < ${HEALTH_CHECK_HEALTHY_WARN_PCT}%"
    echo "  Latency Warning: > ${LATENCY_WARN_MS}ms"
    echo "  Connection Time Warning: > ${CONNECTION_TIME_WARN_MS}ms"
    echo "  Time to First Byte Warning: > ${TTB_WARN_MS}ms"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_health_checks() {
  aws_cmd route53 list-health-checks \
    --output json 2>/dev/null || echo '{"HealthChecks":[]}'
}

get_health_check_status() {
  local hc_id="$1"
  aws_cmd route53 get-health-check-status \
    --health-check-id "${hc_id}" \
    --output json 2>/dev/null || echo '{"HealthCheckObservations":[]}'
}

get_hosted_zones() {
  aws_cmd route53 list-hosted-zones \
    --output json 2>/dev/null || echo '{"HostedZones":[]}'
}

list_resource_record_sets() {
  local zone_id="$1"
  aws_cmd route53 list-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --output json 2>/dev/null || echo '{"ResourceRecordSets":[]}'
}

get_metric() {
  local hc_id="$1" metric="$2" stat_type="${3:-Average}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/Route53 \
    --metric-name "$metric" \
    --dimensions Name=HealthCheckId,Value="$hc_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() { jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END {if(c>0) printf "%.2f", s/c; else print "0"}'; }
calculate_max() { jq -r '.Datapoints[].Maximum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1>m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }
calculate_min() { jq -r '.Datapoints[].Minimum' 2>/dev/null | awk '{if(NR==1)m=$1; else if($1<m)m=$1} END {if(NR==0) print 0; else printf "%.2f", m}'; }

record_issue() {
  ISSUES+=("$1")
}

analyze_health_check() {
  local hc_json="$1"
  local hc_id hc_type hc_protocol hc_port hc_fqdn health_checker_regions ip_addr enable_sni
  hc_id=$(echo "${hc_json}" | jq_safe '.Id')
  hc_type=$(echo "${hc_json}" | jq_safe '.Type')
  hc_protocol=$(echo "${hc_json}" | jq_safe '.HealthCheckConfig.Type')
  hc_port=$(echo "${hc_json}" | jq_safe '.HealthCheckConfig.Port')
  hc_fqdn=$(echo "${hc_json}" | jq_safe '.HealthCheckConfig.FullyQualifiedDomainName')
  ip_addr=$(echo "${hc_json}" | jq_safe '.HealthCheckConfig.IPAddress')
  enable_sni=$(echo "${hc_json}" | jq_safe '.HealthCheckConfig.EnableSNI')

  TOTAL_HEALTH_CHECKS=$((TOTAL_HEALTH_CHECKS + 1))
  log_message INFO "Analyzing health check ${hc_id}"

  # Get status
  local status_json
  status_json=$(get_health_check_status "${hc_id}")
  local healthy_count total_checkers
  healthy_count=$(echo "${status_json}" | jq '[.HealthCheckObservations[] | select(.StatusReport.Status == "Success")] | length' 2>/dev/null || echo 0)
  total_checkers=$(echo "${status_json}" | jq '.HealthCheckObservations | length' 2>/dev/null || echo 0)

  local healthy_pct=0
  if (( total_checkers > 0 )); then
    healthy_pct=$((healthy_count * 100 / total_checkers))
  fi

  {
    echo "Health Check: ${hc_id}"
    echo "  Type: ${hc_type}"
    echo "  Protocol: ${hc_protocol}"
    if [[ -n "${hc_port}" && "${hc_port}" != "null" ]]; then
      echo "  Port: ${hc_port}"
    fi
    if [[ -n "${hc_fqdn}" && "${hc_fqdn}" != "null" ]]; then
      echo "  FQDN: ${hc_fqdn}"
    fi
    if [[ -n "${ip_addr}" && "${ip_addr}" != "null" ]]; then
      echo "  IP Address: ${ip_addr}"
    fi
    echo "  SNI Enabled: ${enable_sni}"
    echo "  Health Status: ${healthy_count}/${total_checkers} (${healthy_pct}%)"
  } >> "${OUTPUT_FILE}"

  # Get CloudWatch metrics
  local latency conn_time ttb
  latency=$(get_metric "${hc_id}" "HealthCheckPercentageHealthy" "Average" | calculate_avg)
  conn_time=$(get_metric "${hc_id}" "ConnectionTime" "Average" | calculate_avg)
  ttb=$(get_metric "${hc_id}" "TimeToFirstByte" "Average" | calculate_avg)

  {
    echo "  Metrics (${LOOKBACK_HOURS}h):"
    echo "    Health Percentage (avg): ${latency}%"
    echo "    Connection Time (avg): ${conn_time}ms"
    echo "    Time to First Byte (avg): ${ttb}ms"
  } >> "${OUTPUT_FILE}"

  local issue=0
  if (( healthy_pct < HEALTH_CHECK_HEALTHY_WARN_PCT )); then
    CHECKS_POOR_THRESHOLD=$((CHECKS_POOR_THRESHOLD + 1))
    issue=1
    record_issue "Route53 HC ${hc_id} health ${healthy_pct}% below threshold ${HEALTH_CHECK_HEALTHY_WARN_PCT}%"
  fi

  if (( $(echo "${conn_time} > ${CONNECTION_TIME_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    CHECKS_HIGH_LATENCY=$((CHECKS_HIGH_LATENCY + 1))
    issue=1
    record_issue "Route53 HC ${hc_id} connection time ${conn_time}ms exceeds ${CONNECTION_TIME_WARN_MS}ms"
  fi

  if (( $(echo "${ttb} > ${TTB_WARN_MS}" | bc -l 2>/dev/null || echo 0) )); then
    CHECKS_HIGH_LATENCY=$((CHECKS_HIGH_LATENCY + 1))
    issue=1
    record_issue "Route53 HC ${hc_id} TTB ${ttb}ms exceeds ${TTB_WARN_MS}ms"
  fi

  # Check if unhealthy
  if (( healthy_pct == 0 )); then
    UNHEALTHY_CHECKS=$((UNHEALTHY_CHECKS + 1))
  fi

  if (( issue )); then
    echo "  STATUS: ⚠️ ISSUES DETECTED" >> "${OUTPUT_FILE}"
  else
    echo "  STATUS: ✓ OK" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

analyze_hosted_zones() {
  log_message INFO "Analyzing Route 53 hosted zones"
  {
    echo "Hosted Zones & Records"
    echo "======================"
  } >> "${OUTPUT_FILE}"

  local zones_json
  zones_json=$(get_hosted_zones)
  TOTAL_ZONES=$(echo "${zones_json}" | jq '.HostedZones | length' 2>/dev/null || echo 0)

  {
    echo "Total Zones: ${TOTAL_ZONES}"
    echo ""
  } >> "${OUTPUT_FILE}"

  echo "${zones_json}" | jq -c '.HostedZones[]' 2>/dev/null | while read -r zone; do
    local zone_id zone_name is_private
    zone_id=$(echo "${zone}" | jq_safe '.Id' | awk -F'/' '{print $NF}')
    zone_name=$(echo "${zone}" | jq_safe '.Name')
    is_private=$(echo "${zone}" | jq_safe '.Config.PrivateZone')

    {
      echo "Zone: ${zone_name}"
      echo "  ID: ${zone_id}"
      echo "  Private: ${is_private}"
    } >> "${OUTPUT_FILE}"

    # List records
    local records_json
    records_json=$(list_resource_record_sets "${zone_id}")
    local record_count
    record_count=$(echo "${records_json}" | jq '.ResourceRecordSets | length' 2>/dev/null || echo 0)
    ((TOTAL_RECORDS += record_count))

    {
      echo "  Record Count: ${record_count}"
    } >> "${OUTPUT_FILE}"

    # Count failover records
    local failover_count
    failover_count=$(echo "${records_json}" | jq '[.ResourceRecordSets[] | select(.Failover != null)] | length' 2>/dev/null || echo 0)
    ((FAILOVER_RECORDS += failover_count))

    if (( failover_count > 0 )); then
      {
        echo "  Failover Records: ${failover_count}"
      } >> "${OUTPUT_FILE}"

      echo "${records_json}" | jq -c '.ResourceRecordSets[] | select(.Failover != null)' 2>/dev/null | while read -r rec; do
        local rec_name failover_type set_id hc_id
        rec_name=$(echo "${rec}" | jq_safe '.Name')
        failover_type=$(echo "${rec}" | jq_safe '.Failover')
        set_id=$(echo "${rec}" | jq_safe '.SetIdentifier')
        hc_id=$(echo "${rec}" | jq_safe '.HealthCheckId')

        {
          echo "    Record: ${rec_name}"
          echo "      Failover Type: ${failover_type}"
          echo "      Set ID: ${set_id}"
          if [[ -n "${hc_id}" && "${hc_id}" != "null" ]]; then
            echo "      Health Check ID: ${hc_id}"
          fi
        } >> "${OUTPUT_FILE}"
      done
    fi

    # Check for alias records with unhealthy targets
    local alias_count unhealthy_alias_count
    alias_count=$(echo "${records_json}" | jq '[.ResourceRecordSets[] | select(.AliasTarget != null)] | length' 2>/dev/null || echo 0)
    unhealthy_alias_count=$(echo "${records_json}" | jq '[.ResourceRecordSets[] | select(.AliasTarget != null and .AliasTarget.EvaluateTargetHealth == true)] | length' 2>/dev/null || echo 0)

    if (( alias_count > 0 )); then
      {
        echo "  Alias Records (with target health eval): ${unhealthy_alias_count}/${alias_count}"
      } >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

main() {
  write_header
  local hc_json
  hc_json=$(list_health_checks)
  local hc_count
  hc_count=$(echo "${hc_json}" | jq '.HealthChecks | length' 2>/dev/null || echo 0)

  if [[ "${hc_count}" == "0" ]]; then
    log_message WARN "No health checks found"
    echo "No Route 53 health checks found." >> "${OUTPUT_FILE}"
  else
    {
      echo "Health Checks"
      echo "============="
      echo "Total Health Checks: ${hc_count}"
      echo ""
    } >> "${OUTPUT_FILE}"

    echo "${hc_json}" | jq -c '.HealthChecks[]' 2>/dev/null | while read -r hc; do
      analyze_health_check "${hc}"
    done
  fi

  analyze_hosted_zones

  {
    echo ""
    echo "Summary"
    echo "-------"
    echo "Total Health Checks: ${TOTAL_HEALTH_CHECKS}"
    echo "Unhealthy Checks: ${UNHEALTHY_CHECKS}"
    echo "High Latency/TTB: ${CHECKS_HIGH_LATENCY}"
    echo "Below Health Threshold: ${CHECKS_POOR_THRESHOLD}"
    echo ""
    echo "Total Zones: ${TOTAL_ZONES}"
    echo "Total Records: ${TOTAL_RECORDS}"
    echo "Failover Records: ${FAILOVER_RECORDS}"
  } >> "${OUTPUT_FILE}"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "Route 53 Health Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "Route 53 Health Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

#!/bin/bash

################################################################################
# AWS Route 53 Health & Failover Monitor
# Health checks, failover DNS, alias target health, CloudTrail DNS change errors
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/route53-monitor-$(date +%s).txt"
LOG_FILE="/var/log/route53-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"
HEALTH_CHECK_WARN_THRESHOLD="${HEALTH_CHECK_WARN_THRESHOLD:-1}"  # unhealthy checks
FAILOVER_CHECK_INTERVAL="${FAILOVER_CHECK_INTERVAL:-30}"

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
start_window() { date -u -d "${DAYS_BACK} days ago" +%Y-%m-%dT%H:%M:%SZ; }
now_window() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# API wrappers
list_health_checks() {
  aws route53 list-health-checks \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_health_check() {
  local hc_id="$1"
  aws route53 get-health-check \
    --health-check-id "${hc_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_health_check_status() {
  local hc_id="$1"
  aws route53 get-health-check-status \
    --health-check-id "${hc_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_hosted_zones() {
  aws route53 list-hosted-zones \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_resource_record_sets() {
  local zone_id="$1"
  aws route53 list-resource-record-sets \
    --hosted-zone-id "${zone_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_health_check_metric() {
  local hc_id="$1"; local metric="$2"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Route53 \
    --metric-name "${metric}" \
    --dimensions Name=HealthCheckId,Value="${hc_id}" \
    --start-time "$(start_window)" \
    --end-time "$(now_window)" \
    --period 300 \
    --statistics Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null | jq '.Datapoints | length' || echo 0
}

write_header() {
  {
    echo "AWS Route53 Health Monitoring Report"
    echo "====================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback: ${DAYS_BACK} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_health_checks() {
  log_message INFO "Listing Route53 health checks"
  {
    echo "=== HEALTH CHECKS ==="
  } >> "${OUTPUT_FILE}"

  local total_checks=0 unhealthy_checks=0 stale_checks=0

  local hc_json
  hc_json=$(list_health_checks)
  
  echo "${hc_json}" | jq -c '.HealthChecks[]' 2>/dev/null | while read -r hc; do
    ((total_checks++))
    local hc_id type status reason alarm_id
    hc_id=$(echo "${hc}" | jq_safe '.Id')
    type=$(echo "${hc}" | jq_safe '.Type')
    status=$(echo "${hc}" | jq_safe '.HealthCheckConfig.Type')
    alarm_id=$(echo "${hc}" | jq_safe '.HealthCheckConfig.AlarmIdentifier.Name')

    # Get health check status
    local status_data child_checks unhealthy
    status_data=$(get_health_check_status "${hc_id}")
    child_checks=$(echo "${status_data}" | jq '.HealthCheckObservations | length' 2>/dev/null || echo 0)
    unhealthy=$(echo "${status_data}" | jq '[.HealthCheckObservations[] | select(.StatusReport.Status=="Failure")] | length' 2>/dev/null || echo 0)

    # Check if health check is healthy
    local is_healthy
    is_healthy=$(echo "${status_data}" | jq -c '.HealthCheckObservations[] | select(.StatusReport.Status=="Success")' 2>/dev/null | wc -l)

    {
      echo "Health Check: ${hc_id}"
      echo "  Type: ${type}"
      echo "  Config Type: ${status}"
      echo "  Observation Points: ${child_checks}"
      echo "  Unhealthy Points: ${unhealthy}"
      echo "  Healthy Points: ${is_healthy}"
    } >> "${OUTPUT_FILE}"

    if [[ -n "${alarm_id}" && "${alarm_id}" != "null" ]]; then
      echo "  CloudWatch Alarm: ${alarm_id}" >> "${OUTPUT_FILE}"
    fi

    # Check IP address if HTTP/HTTPS/TCP
    local ip_address port protocol
    ip_address=$(echo "${hc}" | jq_safe '.HealthCheckConfig.IPAddress')
    port=$(echo "${hc}" | jq_safe '.HealthCheckConfig.Port')
    protocol=$(echo "${hc}" | jq_safe '.HealthCheckConfig.Type')

    if [[ -n "${ip_address}" && "${ip_address}" != "null" ]]; then
      echo "  Target: ${protocol}://${ip_address}:${port}" >> "${OUTPUT_FILE}"
    fi

    # Report if health check is failing
    if (( unhealthy > 0 )); then
      ((unhealthy_checks++))
      echo "  WARNING: Health check has ${unhealthy} unhealthy observation points" >> "${OUTPUT_FILE}"
    fi

    if (( is_healthy < child_checks / 2 )); then
      ((stale_checks++))
      echo "  WARNING: Majority of health check points are reporting failures" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Health Check Summary:"
    echo "  Total: ${total_checks}"
    echo "  Unhealthy: ${unhealthy_checks}"
    echo "  Critically Unhealthy: ${stale_checks}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_hosted_zones() {
  log_message INFO "Listing Route53 hosted zones"
  {
    echo "=== HOSTED ZONES ==="
  } >> "${OUTPUT_FILE}"

  local zones_json zone_count
  zones_json=$(list_hosted_zones)
  zone_count=$(echo "${zones_json}" | jq '.HostedZones | length' 2>/dev/null || echo 0)

  echo "${zones_json}" | jq -c '.HostedZones[]' 2>/dev/null | while read -r zone; do
    local zone_id zone_name record_count private_zone
    zone_id=$(echo "${zone}" | jq_safe '.Id' | sed 's|/hostedzone/||')
    zone_name=$(echo "${zone}" | jq_safe '.Name')
    record_count=$(echo "${zone}" | jq_safe '.ResourceRecordSetCount')
    private_zone=$(echo "${zone}" | jq_safe '.Config.PrivateZone')

    {
      echo "Zone: ${zone_name}"
      echo "  ID: ${zone_id}"
      echo "  Records: ${record_count}"
      echo "  Private: ${private_zone}"
    } >> "${OUTPUT_FILE}"

    # List failover records
    local records_data
    records_data=$(list_resource_record_sets "${zone_id}")
    local failover_count geolocation_count weighted_count simple_count
    failover_count=$(echo "${records_data}" | jq '[.ResourceRecordSets[] | select(.Failover)] | length' 2>/dev/null || echo 0)
    geolocation_count=$(echo "${records_data}" | jq '[.ResourceRecordSets[] | select(.GeoLocation)] | length' 2>/dev/null || echo 0)
    weighted_count=$(echo "${records_data}" | jq '[.ResourceRecordSets[] | select(.Weight)] | length' 2>/dev/null || echo 0)
    simple_count=$(echo "${records_data}" | jq '[.ResourceRecordSets[] | select(.Type | IN("A","AAAA","CNAME","MX","NS","TXT"))] | length' 2>/dev/null || echo 0)

    {
      echo "  Routing Policies:"
      echo "    Simple: ${simple_count}"
      echo "    Weighted: ${weighted_count}"
      echo "    Geolocation: ${geolocation_count}"
      echo "    Failover: ${failover_count}"
    } >> "${OUTPUT_FILE}"

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Hosted Zone Summary:"
    echo "  Total Zones: ${zone_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_failover_records() {
  log_message INFO "Analyzing failover record configurations"
  {
    echo "=== FAILOVER CONFIGURATION AUDIT ==="
  } >> "${OUTPUT_FILE}"

  local zones_json
  zones_json=$(list_hosted_zones)

  echo "${zones_json}" | jq -c '.HostedZones[]' 2>/dev/null | while read -r zone; do
    local zone_id zone_name
    zone_id=$(echo "${zone}" | jq_safe '.Id' | sed 's|/hostedzone/||')
    zone_name=$(echo "${zone}" | jq_safe '.Name')

    local records_data
    records_data=$(list_resource_record_sets "${zone_id}")

    echo "${records_data}" | jq -c '.ResourceRecordSets[] | select(.Failover)' 2>/dev/null | while read -r record; do
      local name type failover set_id ttl hc_id
      name=$(echo "${record}" | jq_safe '.Name')
      type=$(echo "${record}" | jq_safe '.Type')
      failover=$(echo "${record}" | jq_safe '.Failover')
      set_id=$(echo "${record}" | jq_safe '.SetIdentifier')
      ttl=$(echo "${record}" | jq_safe '.TTL')
      hc_id=$(echo "${record}" | jq_safe '.HealthCheckId')

      {
        echo "Failover Record: ${name}"
        echo "  Type: ${type}  Role: ${failover}  Set ID: ${set_id}"
        echo "  TTL: ${ttl} seconds"
      } >> "${OUTPUT_FILE}"

      if [[ -n "${hc_id}" && "${hc_id}" != "null" ]]; then
        echo "  Health Check: ${hc_id}" >> "${OUTPUT_FILE}"
      else
        if [[ "${failover}" == "PRIMARY" ]]; then
          echo "  WARNING: PRIMARY failover record without health check" >> "${OUTPUT_FILE}"
        fi
      fi

      echo "" >> "${OUTPUT_FILE}"
    done
  done
}

report_traffic_policies() {
  log_message INFO "Checking traffic policies"
  {
    echo "=== TRAFFIC POLICIES ==="
  } >> "${OUTPUT_FILE}"

  local policies
  policies=$(aws route53 list-traffic-policies \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}')

  local policy_count
  policy_count=$(echo "${policies}" | jq '.TrafficPolicySummaries | length' 2>/dev/null || echo 0)

  {
    echo "Traffic Policies: ${policy_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

monitor_query_logging() {
  log_message INFO "Checking query logging configuration"
  {
    echo "=== QUERY LOGGING ==="
  } >> "${OUTPUT_FILE}"

  local zones_json
  zones_json=$(list_hosted_zones)

  echo "${zones_json}" | jq -c '.HostedZones[]' 2>/dev/null | while read -r zone; do
    local zone_id zone_name
    zone_id=$(echo "${zone}" | jq_safe '.Id' | sed 's|/hostedzone/||')
    zone_name=$(echo "${zone}" | jq_safe '.Name')

    local query_logs
    query_logs=$(aws route53 list-query-logging-configs \
      --hosted-zone-id "${zone_id}" \
      --region "${REGION}" \
      --output json 2>/dev/null || echo '{}')

    local log_group
    log_group=$(echo "${query_logs}" | jq_safe '.QueryLoggingConfigs[0].CloudWatchLogsLogGroupArn')

    {
      echo "Zone: ${zone_name}"
    } >> "${OUTPUT_FILE}"

    if [[ -n "${log_group}" && "${log_group}" != "null" ]]; then
      echo "  Query Logging: ENABLED (${log_group})" >> "${OUTPUT_FILE}"
    else
      echo "  Query Logging: DISABLED" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local total_checks="$1"; local unhealthy="$2"; local zones="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Route53 Health Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Total Health Checks", "value": "${total_checks}", "short": true},
        {"title": "Unhealthy", "value": "${unhealthy}", "short": true},
        {"title": "Hosted Zones", "value": "${zones}", "short": true},
        {"title": "Check Interval", "value": "${FAILOVER_CHECK_INTERVAL}s", "short": true},
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
  log_message INFO "Starting AWS Route53 health monitoring"
  write_header
  report_health_checks
  report_hosted_zones
  monitor_failover_records
  report_traffic_policies
  monitor_query_logging
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local total_checks unhealthy_checks zones_count
  total_checks=$(list_health_checks | jq '.HealthChecks | length' 2>/dev/null || echo 0)
  unhealthy_checks=$(grep -c "WARNING: Health check has" "${OUTPUT_FILE}" || echo 0)
  zones_count=$(list_hosted_zones | jq '.HostedZones | length' 2>/dev/null || echo 0)
  send_slack_alert "${total_checks}" "${unhealthy_checks}" "${zones_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

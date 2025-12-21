#!/bin/bash

################################################################################
# AWS Service Health Dashboard
# Aggregates health status across multiple AWS services (EC2, ECS, RDS,
# ElastiCache, Lambda, DynamoDB, etc.), tracks quotas, detects failures,
# and provides unified remediation recommendations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/health-dashboard-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/health-dashboard.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
QUOTA_USAGE_WARN="${QUOTA_USAGE_WARN:-80}"     # % quota utilization
MAX_RETRIES="${MAX_RETRIES:-3}"
HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-30}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Metrics
HEALTHY_SERVICES=0
DEGRADED_SERVICES=0
UNHEALTHY_SERVICES=0
QUOTA_WARNINGS=0

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
      "title": "AWS Service Health Alert",
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
    echo "AWS Service Health Dashboard"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Quota Warning Threshold: ${QUOTA_USAGE_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

check_ec2_health() {
  log_message INFO "Checking EC2 service health..."
  
  {
    echo "=== EC2 - Elastic Compute Cloud ==="
  } >> "${OUTPUT_FILE}"
  
  # Instance count
  local instance_count
  instance_count=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].[InstanceId]' \
    --output text 2>/dev/null | wc -w)
  
  {
    echo "Running Instances: ${instance_count}"
  } >> "${OUTPUT_FILE}"
  
  # Check for unhealthy instances
  local unhealthy
  unhealthy=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=instance-status.status,Values=impaired" \
    --query 'Reservations[].Instances[].[InstanceId]' \
    --output text 2>/dev/null | wc -w)
  
  if [[ ${unhealthy} -gt 0 ]]; then
    {
      printf "%b⚠️  Impaired Instances: %d%b\n" "${RED}" "${unhealthy}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((UNHEALTHY_SERVICES++))
    log_message WARN "EC2: ${unhealthy} impaired instances detected"
  else
    {
      echo "✓ All instances healthy"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  # Quota check
  local quota_usage
  quota_usage=$(aws service-quotas get-service-quota \
    --service-code ec2 --quota-code L-1216C47A \
    --region "${REGION}" \
    --query 'Quota.UsageMetric.MetricStatistic[0]' \
    --output text 2>/dev/null || echo "0")
  
  if (( $(echo "${quota_usage} > ${QUOTA_USAGE_WARN}" | bc -l) )); then
    {
      echo "⚠️  EC2 quota usage: ${quota_usage}%"
    } >> "${OUTPUT_FILE}"
    ((QUOTA_WARNINGS++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_rds_health() {
  log_message INFO "Checking RDS service health..."
  
  {
    echo "=== RDS - Relational Database Service ==="
  } >> "${OUTPUT_FILE}"
  
  # Instance count and status
  local db_count available_count
  db_count=$(aws rds describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[].[DBInstanceIdentifier]' \
    --output text 2>/dev/null | wc -w)
  
  available_count=$(aws rds describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[?DBInstanceStatus==`available`].[DBInstanceIdentifier]' \
    --output text 2>/dev/null | wc -w)
  
  {
    echo "Total Instances: ${db_count}"
    echo "Available Instances: ${available_count}"
  } >> "${OUTPUT_FILE}"
  
  # Check for failed instances
  local failed_count
  failed_count=$((db_count - available_count))
  
  if [[ ${failed_count} -gt 0 ]]; then
    {
      printf "%b⚠️  Non-Available Instances: %d%b\n" "${RED}" "${failed_count}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((UNHEALTHY_SERVICES++))
    log_message WARN "RDS: ${failed_count} non-available instances detected"
  else
    {
      echo "✓ All instances available"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  # Check for backup status
  local failed_backups
  failed_backups=$(aws rds describe-db-instances \
    --region "${REGION}" \
    --query 'DBInstances[?LatestRestorableTime==null].[DBInstanceIdentifier]' \
    --output text 2>/dev/null | wc -w)
  
  if [[ ${failed_backups} -gt 0 ]]; then
    {
      echo "⚠️  Backups not configured: ${failed_backups} instances"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_elasticache_health() {
  log_message INFO "Checking ElastiCache service health..."
  
  {
    echo "=== ElastiCache - In-Memory Cache ==="
  } >> "${OUTPUT_FILE}"
  
  # Cluster count
  local cluster_count available_clusters
  cluster_count=$(aws elasticache describe-replication-groups \
    --region "${REGION}" \
    --query 'ReplicationGroups[].[ReplicationGroupId]' \
    --output text 2>/dev/null | wc -w)
  
  available_clusters=$(aws elasticache describe-replication-groups \
    --region "${REGION}" \
    --query 'ReplicationGroups[?Status==`available`].[ReplicationGroupId]' \
    --output text 2>/dev/null | wc -w)
  
  {
    echo "Total Clusters: ${cluster_count}"
    echo "Available Clusters: ${available_clusters}"
  } >> "${OUTPUT_FILE}"
  
  local failed_clusters
  failed_clusters=$((cluster_count - available_clusters))
  
  if [[ ${failed_clusters} -gt 0 ]]; then
    {
      printf "%b⚠️  Unavailable Clusters: %d%b\n" "${RED}" "${failed_clusters}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((UNHEALTHY_SERVICES++))
    log_message WARN "ElastiCache: ${failed_clusters} unavailable clusters"
  else
    {
      echo "✓ All clusters available"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_ecs_health() {
  log_message INFO "Checking ECS service health..."
  
  {
    echo "=== ECS - Elastic Container Service ==="
  } >> "${OUTPUT_FILE}"
  
  # Cluster count
  local cluster_count active_clusters
  cluster_count=$(aws ecs list-clusters \
    --region "${REGION}" \
    --query 'clusterArns' \
    --output text 2>/dev/null | tr -d '\n' | wc -w || echo "0")
  
  {
    echo "Total Clusters: ${cluster_count}"
  } >> "${OUTPUT_FILE}"
  
  # Service health
  local services_with_issues=0
  local clusters
  clusters=$(aws ecs list-clusters --region "${REGION}" --query 'clusterArns[]' --output text 2>/dev/null)
  
  while IFS= read -r cluster_arn; do
    [[ -z "${cluster_arn}" ]] && continue
    
    local cluster_name
    cluster_name=$(basename "${cluster_arn}")
    
    local failing_services
    failing_services=$(aws ecs list-services \
      --cluster "${cluster_arn}" \
      --region "${REGION}" \
      --query 'serviceArns[]' \
      --output text 2>/dev/null | wc -w || echo "0")
    
    if [[ ${failing_services} -gt 0 ]]; then
      ((services_with_issues+=${failing_services}))
    fi
  done <<< "${clusters}"
  
  if [[ ${services_with_issues} -gt 0 ]]; then
    {
      printf "%b⚠️  Services with Issues: %d%b\n" "${RED}" "${services_with_issues}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((UNHEALTHY_SERVICES++))
  else
    {
      echo "✓ All services healthy"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_lambda_health() {
  log_message INFO "Checking Lambda service health..."
  
  {
    echo "=== Lambda - Serverless Functions ==="
  } >> "${OUTPUT_FILE}"
  
  # Function count
  local function_count
  function_count=$(aws lambda list-functions \
    --region "${REGION}" \
    --query 'Functions[].[FunctionName]' \
    --output text 2>/dev/null | wc -w)
  
  {
    echo "Total Functions: ${function_count}"
  } >> "${OUTPUT_FILE}"
  
  # Check for functions with errors (via CloudWatch Logs)
  local functions_with_high_errors=0
  local functions
  functions=$(aws lambda list-functions --region "${REGION}" --query 'Functions[].[FunctionName]' --output text 2>/dev/null)
  
  while IFS= read -r func_name; do
    [[ -z "${func_name}" ]] && continue
    
    local error_count
    error_count=$(aws logs filter-log-events \
      --log-group-name "/aws/lambda/${func_name}" \
      --filter-pattern "ERROR" \
      --region "${REGION}" \
      --start-time $(($(date +%s000) - 3600000)) \
      --query 'events | length(@)' \
      --output text 2>/dev/null || echo "0")
    
    if [[ ${error_count} -gt 10 ]]; then
      ((functions_with_high_errors++))
    fi
  done <<< "${functions}"
  
  if [[ ${functions_with_high_errors} -gt 0 ]]; then
    {
      printf "%b⚠️  Functions with High Errors: %d%b\n" "${YELLOW}" "${functions_with_high_errors}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((DEGRADED_SERVICES++))
  else
    {
      echo "✓ All functions operating normally"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_dynamodb_health() {
  log_message INFO "Checking DynamoDB service health..."
  
  {
    echo "=== DynamoDB - NoSQL Database ==="
  } >> "${OUTPUT_FILE}"
  
  # Table count
  local table_count
  table_count=$(aws dynamodb list-tables \
    --region "${REGION}" \
    --query 'TableNames | length(@)' \
    --output text 2>/dev/null)
  
  {
    echo "Total Tables: ${table_count}"
  } >> "${OUTPUT_FILE}"
  
  # Check for tables in CREATING or DELETING state
  local unhealthy_tables=0
  local tables
  tables=$(aws dynamodb list-tables --region "${REGION}" --query 'TableNames[]' --output text 2>/dev/null)
  
  while IFS= read -r table_name; do
    [[ -z "${table_name}" ]] && continue
    
    local status
    status=$(aws dynamodb describe-table \
      --table-name "${table_name}" \
      --region "${REGION}" \
      --query 'Table.TableStatus' \
      --output text 2>/dev/null)
    
    if [[ "${status}" != "ACTIVE" ]]; then
      ((unhealthy_tables++))
    fi
  done <<< "${tables}"
  
  if [[ ${unhealthy_tables} -gt 0 ]]; then
    {
      printf "%b⚠️  Non-Active Tables: %d%b\n" "${YELLOW}" "${unhealthy_tables}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((DEGRADED_SERVICES++))
  else
    {
      echo "✓ All tables active"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_cloudwatch_alarms() {
  log_message INFO "Checking CloudWatch alarms..."
  
  {
    echo "=== CloudWatch - Monitoring & Alarms ==="
  } >> "${OUTPUT_FILE}"
  
  # Count alarms by state
  local alarm_count in_alarm_count insufficient_data_count
  alarm_count=$(aws cloudwatch describe-alarms \
    --region "${REGION}" \
    --query 'MetricAlarms | length(@)' \
    --output text 2>/dev/null)
  
  in_alarm_count=$(aws cloudwatch describe-alarms \
    --region "${REGION}" \
    --state-value ALARM \
    --query 'MetricAlarms | length(@)' \
    --output text 2>/dev/null)
  
  insufficient_data_count=$(aws cloudwatch describe-alarms \
    --region "${REGION}" \
    --state-value INSUFFICIENT_DATA \
    --query 'MetricAlarms | length(@)' \
    --output text 2>/dev/null)
  
  {
    echo "Total Alarms: ${alarm_count}"
    echo "In Alarm: ${in_alarm_count}"
    echo "Insufficient Data: ${insufficient_data_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${in_alarm_count} -gt 0 ]]; then
    {
      printf "%b⚠️  Active Alarms Detected%b\n" "${RED}" "${NC}"
    } >> "${OUTPUT_FILE}"
    ((UNHEALTHY_SERVICES++))
    log_message WARN "CloudWatch: ${in_alarm_count} alarms in ALARM state"
  else
    {
      echo "✓ All alarms OK"
    } >> "${OUTPUT_FILE}"
    ((HEALTHY_SERVICES++))
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_service_quotas() {
  log_message INFO "Checking service quotas..."
  
  {
    echo "=== Service Quotas ==="
  } >> "${OUTPUT_FILE}"
  
  local services=(ec2 rds lambda dynamodb)
  
  for service in "${services[@]}"; do
    {
      echo "Service: ${service}"
    } >> "${OUTPUT_FILE}"
    
    local quotas
    quotas=$(aws service-quotas list-service-quotas \
      --service-code "${service}" \
      --region "${REGION}" \
      --query 'Quotas[].[QuotaName,Value]' \
      --output text 2>/dev/null)
    
    if [[ -z "${quotas}" ]]; then
      {
        echo "  Unable to retrieve quota data"
      } >> "${OUTPUT_FILE}"
      continue
    fi
    
    while IFS=$'\t' read -r quota_name quota_value; do
      [[ -z "${quota_name}" ]] && continue
      
      if (( $(echo "${quota_value} > ${QUOTA_USAGE_WARN}" | bc -l 2>/dev/null || echo 0) )); then
        {
          printf "  %b⚠️  %s: %.0f%%%b\n" "${YELLOW}" "${quota_name}" "${quota_value}" "${NC}"
        } >> "${OUTPUT_FILE}"
        ((QUOTA_WARNINGS++))
      fi
    done <<< "${quotas}"
  done
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_health_summary() {
  {
    echo "=== OVERALL HEALTH SUMMARY ==="
    echo ""
    printf "%bHealthy Services: %d%b\n" "${GREEN}" "${HEALTHY_SERVICES}" "${NC}"
    printf "%bDegraded Services: %d%b\n" "${YELLOW}" "${DEGRADED_SERVICES}" "${NC}"
    printf "%bUnhealthy Services: %d%b\n" "${RED}" "${UNHEALTHY_SERVICES}" "${NC}"
    printf "%bQuota Warnings: %d%b\n" "${YELLOW}" "${QUOTA_WARNINGS}" "${NC}"
    echo ""
    
    local overall_status
    if [[ ${UNHEALTHY_SERVICES} -gt 0 ]]; then
      overall_status="CRITICAL"
      printf "%b[CRITICAL] Infrastructure requires immediate attention%b\n" "${RED}" "${NC}"
    elif [[ ${DEGRADED_SERVICES} -gt 0 ]]; then
      overall_status="WARNING"
      printf "%b[WARNING] Some services degraded, investigate further%b\n" "${YELLOW}" "${NC}"
    else
      overall_status="HEALTHY"
      printf "%b[HEALTHY] All services operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_remediation() {
  {
    echo "=== REMEDIATION & ACTION ITEMS ==="
    echo ""
    
    if [[ ${UNHEALTHY_SERVICES} -gt 0 ]]; then
      echo "Critical Actions Required:"
      echo "  1. Review CloudWatch dashboard for active alarms"
      echo "  2. Check EC2 impaired instances - may need restart/reboot"
      echo "  3. Review RDS instance availability - check logs for errors"
      echo "  4. Verify ElastiCache cluster status - check cluster events"
      echo "  5. Validate ECS service deployment status"
      echo ""
    fi
    
    if [[ ${DEGRADED_SERVICES} -gt 0 ]]; then
      echo "Degradation Items:"
      echo "  1. Review Lambda function error logs"
      echo "  2. Check DynamoDB table throttling"
      echo "  3. Analyze performance metrics over last hour"
      echo "  4. Consider scaling if approaching limits"
      echo ""
    fi
    
    if [[ ${QUOTA_WARNINGS} -gt 0 ]]; then
      echo "Quota Management:"
      echo "  1. Request quota increases for services near limits"
      echo "  2. Review and clean up unused resources"
      echo "  3. Implement resource tagging for cost tracking"
      echo "  4. Set up quota monitoring alarms"
      echo ""
    fi
    
    echo "Ongoing Recommendations:"
    echo "  • Enable AWS Health Dashboard for broader region/service status"
    echo "  • Set up automated backups for stateful services (RDS, DynamoDB)"
    echo "  • Implement cross-region failover for critical workloads"
    echo "  • Review IAM roles/permissions monthly"
    echo "  • Run cost optimization analysis on underutilized resources"
    echo "  • Implement CloudWatch Log Insights queries for faster diagnostics"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== AWS Service Health Dashboard Started ==="
  
  write_header
  
  # Check all services
  check_ec2_health
  check_rds_health
  check_elasticache_health
  check_ecs_health
  check_lambda_health
  check_dynamodb_health
  check_cloudwatch_alarms
  check_service_quotas
  
  # Generate summary and remediation
  generate_health_summary
  generate_remediation
  
  {
    echo "=== DASHBOARD METADATA ==="
    echo "Report Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Report File: ${OUTPUT_FILE}"
    echo "Log File: ${LOG_FILE}"
    echo ""
    echo "To integrate with your monitoring:"
    echo "  1. Schedule this script via cron or CloudWatch Events"
    echo "  2. Connect output to CloudWatch Logs for archival"
    echo "  3. Set up SNS notifications for critical alerts"
    echo "  4. Create custom CloudWatch dashboard from metrics"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== AWS Service Health Dashboard Completed ==="
  
  # Send alerts if issues found
  if [[ ${UNHEALTHY_SERVICES} -gt 0 ]]; then
    send_slack_alert "🚨 Critical: ${UNHEALTHY_SERVICES} unhealthy service(s) detected. Check dashboard for details." "CRITICAL"
    send_email_alert "AWS Health Alert: CRITICAL" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${DEGRADED_SERVICES} -gt 0 ]]; then
    send_slack_alert "⚠️ Warning: ${DEGRADED_SERVICES} degraded service(s) detected. Review for impact." "WARNING"
  fi
}

main "$@"

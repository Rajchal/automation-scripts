#!/bin/bash

################################################################################
# AWS Service Quotas Monitor
# Lists key AWS service quotas and computes current usage for common resources.
# Alerts when usage exceeds configurable thresholds.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/service-quotas-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/service-quotas-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
USAGE_WARN_PERCENT="${USAGE_WARN_PERCENT:-80}"   # warn at >= this % of quota

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
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

send_slack_alert() {
  local message="$1"; local severity="${2:-WARNING}"
  [[ -z "${SLACK_WEBHOOK}" ]] && return
  local color
  case "${severity}" in
    CRITICAL) color="danger" ;;
    WARNING)  color="warning" ;;
    INFO)     color="good" ;;
    *)        color="warning" ;;
  esac
  local payload
  payload=$(cat <<EOF
{
  "attachments": [
    {"color": "${color}", "title": "Service Quotas Alert", "text": "${message}", "ts": $(date +%s)}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || true
}

send_email_alert() {
  local subject="$1"; local body="$2"
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then return; fi
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS Service Quotas Usage Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Warn Threshold: ${USAGE_WARN_PERCENT}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

############################################
# Usage collectors
############################################
count_eips() {
  aws ec2 describe-addresses --region "${REGION}" --output json 2>/dev/null | jq '.Addresses | length' 2>/dev/null || echo 0
}

count_vpcs() {
  aws ec2 describe-vpcs --region "${REGION}" --output json 2>/dev/null | jq '.Vpcs | length' 2>/dev/null || echo 0
}

max_security_groups_per_vpc() {
  local sgs vpc_counts
  sgs=$(aws ec2 describe-security-groups --region "${REGION}" --output json 2>/dev/null)
  vpc_counts=$(echo "${sgs}" | jq -r '.SecurityGroups[] | select(.VpcId!=null) | .VpcId' | sort | uniq -c | awk '{print $1}' 2>/dev/null)
  if [[ -z "${vpc_counts}" ]]; then echo 0; return; fi
  echo "${vpc_counts}" | sort -nr | head -1
}

count_nat_gateways() {
  aws ec2 describe-nat-gateways --region "${REGION}" --output json 2>/dev/null | jq '.NatGateways | length' 2>/dev/null || echo 0
}

count_alb() {
  aws elbv2 describe-load-balancers --region "${REGION}" --output json 2>/dev/null | jq -r '.LoadBalancers[]? | select(.Type=="application") | .LoadBalancerArn' | wc -l
}

count_nlb() {
  aws elbv2 describe-load-balancers --region "${REGION}" --output json 2>/dev/null | jq -r '.LoadBalancers[]? | select(.Type=="network") | .LoadBalancerArn' | wc -l
}

count_rds_instances() {
  aws rds describe-db-instances --region "${REGION}" --output json 2>/dev/null | jq '.DBInstances | length' 2>/dev/null || echo 0
}

count_sqs_queues() {
  aws sqs list-queues --region "${REGION}" --output json 2>/dev/null | jq '.QueueUrls | length' 2>/dev/null || echo 0
}

count_ecr_repos() {
  aws ecr describe-repositories --region "${REGION}" --output json 2>/dev/null | jq '.repositories | length' 2>/dev/null || echo 0
}

############################################
# Quotas
############################################
list_ec2_quotas() {
  aws service-quotas list-aws-default-service-quotas --service-code ec2 --region "${REGION}" --output json 2>/dev/null || echo '{"Quotas":[]}'
}

list_elbv2_quotas() {
  aws service-quotas list-aws-default-service-quotas --service-code elasticloadbalancing --region "${REGION}" --output json 2>/dev/null || echo '{"Quotas":[]}'
}

list_rds_quotas() {
  aws service-quotas list-aws-default-service-quotas --service-code rds --region "${REGION}" --output json 2>/dev/null || echo '{"Quotas":[]}'
}

list_sqs_quotas() {
  aws service-quotas list-aws-default-service-quotas --service-code sqs --region "${REGION}" --output json 2>/dev/null || echo '{"Quotas":[]}'
}

list_ecr_quotas() {
  aws service-quotas list-aws-default-service-quotas --service-code ecr --region "${REGION}" --output json 2>/dev/null || echo '{"Quotas":[]}'
}

print_quota_line() {
  local name="$1"; local value="$2"; local usage="$3"; local unit="$4"
  local percent=0
  if [[ "${value}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "${usage}" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "${value} > 0" | bc -l) )); then
    percent=$(awk -v u="${usage}" -v v="${value}" 'BEGIN{printf "%.1f", (u/v)*100.0}')
  fi
  local color="${GREEN}"
  if (( $(echo "${percent} >= ${USAGE_WARN_PERCENT}" | bc -l) )); then color="${YELLOW}"; fi
  if (( $(echo "${percent} >= 95" | bc -l) )); then color="${RED}"; fi
  printf "%b%-45s %-12s used: %-6s (%s%%)%b\n" "${color}" "${name}" "${value} ${unit}" "${usage}" "${percent}" "${NC}" >> "${OUTPUT_FILE}"
}

monitor_ec2() {
  {
    echo "=== EC2 / VPC ==="
  } >> "${OUTPUT_FILE}"
  local quotas_json; quotas_json=$(list_ec2_quotas)
  local eips_usage vpcs_usage sgs_usage nat_usage
  eips_usage=$(count_eips)
  vpcs_usage=$(count_vpcs)
  sgs_usage=$(max_security_groups_per_vpc)
  nat_usage=$(count_nat_gateways)
  
  echo "${quotas_json}" | jq -r '.Quotas[] | "\(.QuotaName)|\(.Value)|\(.Unit)"' | while IFS='|' read -r qname qvalue qunit; do
    case "${qname}" in
      *Elastic*IP*addresses*) print_quota_line "${qname}" "${qvalue}" "${eips_usage}" "${qunit}" ;;
      *VPCs*per*Region*|*VPCs*per*region*) print_quota_line "${qname}" "${qvalue}" "${vpcs_usage}" "${qunit}" ;;
      *Security*groups*per*VPC*) print_quota_line "${qname}" "${qvalue}" "${sgs_usage}" "${qunit}" ;;
      *NAT*gateways*per*Region*|*NAT*gateways*per*region*) print_quota_line "${qname}" "${qvalue}" "${nat_usage}" "${qunit}" ;;
      *) ;; # skip others
    esac
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_elbv2() {
  {
    echo "=== Elastic Load Balancing (v2) ==="
  } >> "${OUTPUT_FILE}"
  local quotas_json; quotas_json=$(list_elbv2_quotas)
  local alb_usage nlb_usage
  alb_usage=$(count_alb)
  nlb_usage=$(count_nlb)
  echo "${quotas_json}" | jq -r '.Quotas[] | "\(.QuotaName)|\(.Value)|\(.Unit)"' | while IFS='|' read -r qname qvalue qunit; do
    case "${qname}" in
      *Application*Load*Balancers*per*Region*|*Application*Load*Balancers*per*region*) print_quota_line "${qname}" "${qvalue}" "${alb_usage}" "${qunit}" ;;
      *Network*Load*Balancers*per*Region*|*Network*Load*Balancers*per*region*) print_quota_line "${qname}" "${qvalue}" "${nlb_usage}" "${qunit}" ;;
      *) ;;
    esac
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_rds() {
  {
    echo "=== RDS ==="
  } >> "${OUTPUT_FILE}"
  local quotas_json; quotas_json=$(list_rds_quotas)
  local rds_usage; rds_usage=$(count_rds_instances)
  echo "${quotas_json}" | jq -r '.Quotas[] | "\(.QuotaName)|\(.Value)|\(.Unit)"' | while IFS='|' read -r qname qvalue qunit; do
    case "${qname}" in
      *DB*instances*per*Region*|*DB*instances*per*region*) print_quota_line "${qname}" "${qvalue}" "${rds_usage}" "${qunit}" ;;
      *) ;;
    esac
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_sqs() {
  {
    echo "=== SQS ==="
  } >> "${OUTPUT_FILE}"
  local quotas_json; quotas_json=$(list_sqs_quotas)
  local sqs_usage; sqs_usage=$(count_sqs_queues)
  echo "${quotas_json}" | jq -r '.Quotas[] | "\(.QuotaName)|\(.Value)|\(.Unit)"' | while IFS='|' read -r qname qvalue qunit; do
    case "${qname}" in
      *Queues*per*Region*|*Queues*per*region*) print_quota_line "${qname}" "${qvalue}" "${sqs_usage}" "${qunit}" ;;
      *) ;;
    esac
  done
  echo "" >> "${OUTPUT_FILE}"
}

monitor_ecr() {
  {
    echo "=== ECR ==="
  } >> "${OUTPUT_FILE}"
  local quotas_json; quotas_json=$(list_ecr_quotas)
  local ecr_usage; ecr_usage=$(count_ecr_repos)
  echo "${quotas_json}" | jq -r '.Quotas[] | "\(.QuotaName)|\(.Value)|\(.Unit)"' | while IFS='|' read -r qname qvalue qunit; do
    case "${qname}" in
      *Repositories*per*account*|*Repositories*per*Account*) print_quota_line "${qname}" "${qvalue}" "${ecr_usage}" "${qunit}" ;;
      *) ;;
    esac
  done
  echo "" >> "${OUTPUT_FILE}"
}

alert_if_needed() {
  local warn_lines
  warn_lines=$(grep -E "\((${USAGE_WARN_PERCENT}|9[5-9])\)%\)" "${OUTPUT_FILE}" || true)
  if [[ -n "${warn_lines}" ]]; then
    local msg="Service quota usage warnings:\n${warn_lines}"
    send_slack_alert "${msg}" "WARNING"
    send_email_alert "AWS Service Quotas Warning" "${msg}"
  fi
}

main() {
  log_message INFO "=== Service Quotas Monitor Started ==="
  write_header
  monitor_ec2
  monitor_elbv2
  monitor_rds
  monitor_sqs
  monitor_ecr
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  alert_if_needed
  cat "${OUTPUT_FILE}"
  log_message INFO "=== Service Quotas Monitor Completed ==="
}

main "$@"

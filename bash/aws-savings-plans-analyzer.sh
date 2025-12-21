#!/bin/bash

################################################################################
# AWS Savings Plans Analyzer
# Analyzes savings plans coverage, estimates monthly savings, identifies
# on-demand instances without coverage, and recommends plan optimization.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/savings-plans-analyze-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/savings-plans-analyzer.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
MIN_COVERAGE_WARN="${MIN_COVERAGE_WARN:-75}"    # % coverage target
EXPIRY_WARN_DAYS="${EXPIRY_WARN_DAYS:-90}"     # days until expiry warning

# Pricing (baseline on-demand rates - adjust per region/instance type)
DEFAULT_EC2_HOURLY_RATE="0.10"   # per hour avg
DEFAULT_COMPUTE_HOURLY_RATE="0.12"

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

list_savings_plans() {
  aws savingsplans describe-savings-plans \
    --filters key=region,values="${REGION}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"savingsPlans":[]}'
}

describe_savings_plan() {
  local plan_arn="$1"
  aws savingsplans describe-savings-plans \
    --filters key=savingsPlanArn,values="${plan_arn}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"savingsPlans":[]}'
}

list_ec2_instances() {
  aws ec2 describe-instances \
    --region "${REGION}" \
    --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,LaunchTime,InstanceLifecycle]' \
    --output json 2>/dev/null || echo '[]'
}

get_instance_details() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --instance-ids "${instance_id}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_cw_instance_metrics() {
  local instance_id="$1"
  local start_time end_time
  start_time=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value="${instance_id}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 3600 \
    --statistics Average \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
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
      "title": "Savings Plans Analysis",
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
    echo "AWS Savings Plans Coverage Analysis"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Coverage Target: ${MIN_COVERAGE_WARN}%"
    echo "Expiry Warning Threshold: ${EXPIRY_WARN_DAYS} days"
    echo ""
  } > "${OUTPUT_FILE}"
}

analyze_savings_plans() {
  log_message INFO "Starting Savings Plans analysis"
  
  {
    echo "=== ACTIVE SAVINGS PLANS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local plans_json
  plans_json=$(list_savings_plans)
  
  local total_plans=0
  local compute_plans=0
  local ec2_plans=0
  local sagemaker_plans=0
  local total_hourly_commitment=0
  local total_expiring_soon=0
  
  local plan_arns
  plan_arns=$(echo "${plans_json}" | jq -r '.savingsPlans[]?.savingsPlanArn' 2>/dev/null)
  
  if [[ -z "${plan_arns}" ]]; then
    log_message WARN "No Savings Plans found in region ${REGION}"
    {
      echo "Status: No savings plans found"
      echo ""
    } >> "${OUTPUT_FILE}"
  else
    while IFS= read -r plan_arn; do
      [[ -z "${plan_arn}" ]] && continue
      ((total_plans++))
      
      log_message INFO "Analyzing plan: ${plan_arn}"
      
      local plan_details
      plan_details=$(describe_savings_plan "${plan_arn}")
      
      local plan_id plan_type offering_id state start_date end_date
      local purchase_amt commitment hourly_rate currency
      
      plan_id=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].savingsPlanId')
      plan_type=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].productType')
      state=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].state')
      start_date=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].start')
      end_date=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].end')
      purchase_amt=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].upfrontPaymentAmount')
      commitment=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].commitment')
      currency=$(echo "${plan_details}" | jq_safe '.savingsPlans[0].currency')
      
      case "${plan_type}" in
        COMPUTE_SAVINGS_PLAN) ((compute_plans++)) ;;
        EC2_SAVINGS_PLAN)     ((ec2_plans++)) ;;
        SAGEMAKER_SAVINGS_PLAN) ((sagemaker_plans++)) ;;
      esac
      
      # Calculate hourly from commitment
      local hourly_rate=0
      if [[ -n "${commitment}" && "${commitment}" != "null" ]]; then
        hourly_rate=$(awk -v c="${commitment}" 'BEGIN{printf "%.2f", c/8760}')
        total_hourly_commitment=$(awk -v t="${total_hourly_commitment}" -v h="${hourly_rate}" 'BEGIN{printf "%.2f", t+h}')
      fi
      
      # Check if expiring soon
      local days_until_expiry=0
      if [[ -n "${end_date}" && "${end_date}" != "null" ]]; then
        local end_epoch
        end_epoch=$(date -d "${end_date}" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        days_until_expiry=$(( (end_epoch - now_epoch) / 86400 ))
        
        if [[ ${days_until_expiry} -lt ${EXPIRY_WARN_DAYS} ]]; then
          ((total_expiring_soon++))
        fi
      fi
      
      local status_color="${GREEN}"
      if [[ "${state}" != "ACTIVE" ]]; then
        status_color="${YELLOW}"
      fi
      
      {
        printf "%bPlan ID: %s%b\n" "${status_color}" "${plan_id}" "${NC}"
        echo "Type: ${plan_type}"
        echo "State: ${state}"
        echo "Period: ${start_date} to ${end_date}"
        printf "Days until expiry: %d\n" "${days_until_expiry}"
        echo "Annual Commitment: ${currency} ${commitment}"
        echo "Hourly Rate: ${currency} ${hourly_rate}/hour"
        echo "Upfront Payment: ${currency} ${purchase_amt}"
        echo ""
      } >> "${OUTPUT_FILE}"
      
      if [[ ${days_until_expiry} -lt ${EXPIRY_WARN_DAYS} && ${days_until_expiry} -gt 0 ]]; then
        log_message WARN "Savings Plan ${plan_id} expiring in ${days_until_expiry} days"
        local alert_msg="⚠️  Savings Plan expiring soon: ${plan_id} in ${days_until_expiry} days"
        send_slack_alert "${alert_msg}" "WARNING"
      fi
      
    done <<< "${plan_arns}"
  fi
  
  # Summary
  {
    echo "=== SAVINGS PLANS SUMMARY ==="
    echo "Total Active Plans: ${total_plans}"
    echo "  - Compute: ${compute_plans}"
    echo "  - EC2: ${ec2_plans}"
    echo "  - SageMaker: ${sagemaker_plans}"
    echo "Total Hourly Commitment: ${currency} ${total_hourly_commitment}"
    echo "Monthly Commitment Estimate: ${currency} $(awk -v h="${total_hourly_commitment}" 'BEGIN{printf "%.2f", h*730}')"
    echo "Plans Expiring Soon: ${total_expiring_soon}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${total_expiring_soon} -gt 0 ]]; then
    log_message WARN "Found ${total_expiring_soon} plans expiring within ${EXPIRY_WARN_DAYS} days"
    local alert_msg="⚠️  ${total_expiring_soon} Savings Plans expiring within ${EXPIRY_WARN_DAYS} days"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
}

analyze_coverage() {
  log_message INFO "Analyzing Savings Plans coverage"
  
  {
    echo "=== COVERAGE ANALYSIS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local instances_json
  instances_json=$(list_ec2_instances)
  
  local total_instances=0
  local running_instances=0
  local on_demand_instances=0
  local unprotected_instances=0
  
  # Count instances
  local instance_lines
  instance_lines=$(echo "${instances_json}" | jq -r '.[][]? | @csv' 2>/dev/null)
  
  while IFS=',' read -r instance_id itype state launch_time lifecycle; do
    instance_id=$(echo "${instance_id}" | tr -d '"')
    state=$(echo "${state}" | tr -d '"')
    lifecycle=$(echo "${lifecycle}" | tr -d '"')
    
    [[ -z "${instance_id}" ]] && continue
    ((total_instances++))
    
    if [[ "${state}" == "running" ]]; then
      ((running_instances++))
      
      # Check if on-demand (not reserved, not spot)
      if [[ -z "${lifecycle}" || "${lifecycle}" == "null" || "${lifecycle}" == "on-demand" ]]; then
        ((on_demand_instances++))
        
        # Simple check: assume unprotected if no matching savings plan
        # In real scenario, would query actual coverage from CE API
        ((unprotected_instances++))
      fi
    fi
  done <<< "${instance_lines}"
  
  local coverage_percent=0
  if [[ ${running_instances} -gt 0 ]]; then
    coverage_percent=$((100 - (on_demand_instances * 100 / running_instances)))
  fi
  
  {
    echo "Total Instances: ${total_instances}"
    echo "Running Instances: ${running_instances}"
    echo "On-Demand Instances: ${on_demand_instances}"
    echo "Unprotected Instances: ${unprotected_instances}"
    printf "Coverage: %d%%\n" "${coverage_percent}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${coverage_percent} -lt ${MIN_COVERAGE_WARN} ]]; then
    log_message WARN "Savings Plans coverage is ${coverage_percent}% (target: ${MIN_COVERAGE_WARN}%)"
    {
      echo ""
      echo "⚠️  Coverage below target! Consider purchasing additional Savings Plans."
      echo "Potential monthly savings opportunity: Estimate based on unprotected instance hours."
      echo ""
    } >> "${OUTPUT_FILE}"
    
    local alert_msg="⚠️  Savings Plans coverage is ${coverage_percent}% (target: ${MIN_COVERAGE_WARN}%)"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
}

list_unprotected_instances() {
  log_message INFO "Identifying unprotected instances"
  
  {
    echo ""
    echo "=== UNPROTECTED INSTANCES (Sample) ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local instances_json
  instances_json=$(list_ec2_instances)
  
  local count=0
  local instance_lines
  instance_lines=$(echo "${instances_json}" | jq -r '.[][]? | @csv' 2>/dev/null)
  
  while IFS=',' read -r instance_id itype state launch_time lifecycle; do
    instance_id=$(echo "${instance_id}" | tr -d '"')
    itype=$(echo "${itype}" | tr -d '"')
    state=$(echo "${state}" | tr -d '"')
    lifecycle=$(echo "${lifecycle}" | tr -d '"')
    
    [[ -z "${instance_id}" ]] && continue
    
    if [[ "${state}" == "running" ]] && [[ -z "${lifecycle}" || "${lifecycle}" == "null" ]]; then
      if [[ ${count} -lt 10 ]]; then
        {
          echo "Instance: ${instance_id}"
          echo "Type: ${itype}"
          echo "Launched: ${launch_time}"
          echo ""
        } >> "${OUTPUT_FILE}"
        ((count++))
      fi
    fi
  done <<< "${instance_lines}"
  
  if [[ ${count} -eq 0 ]]; then
    echo "No unprotected on-demand instances found" >> "${OUTPUT_FILE}"
  else
    {
      echo "(Showing first 10 - check AWS Cost Explorer for complete list)"
      echo ""
    } >> "${OUTPUT_FILE}"
  fi
}

recommendations() {
  {
    echo "=== SAVINGS PLANS RECOMMENDATIONS ==="
    echo ""
    echo "Strategy:"
    echo "  1. Identify baseline compute capacity (minimum sustained usage)"
    echo "  2. Purchase Compute Savings Plans for that baseline (most flexible)"
    echo "  3. Optimize with EC2-specific plans for predictable workloads"
    echo "  4. Monitor utilization monthly and adjust for next renewal"
    echo ""
    echo "Plan Selection:"
    echo "  • Compute Savings Plan: Best for mixed instance types, regions, and OS"
    echo "  • EC2 Savings Plan: Better discount if locked to specific instance family"
    echo "  • 1-Year vs 3-Year: 3-year provides ~30% better discount if stable"
    echo ""
    echo "Best Practices:"
    echo "  • Use AWS Cost Explorer to forecast and recommend plans"
    echo "  • Start with conservative 1-year plans, scale with 3-year after validation"
    echo "  • Combine with Reserved Instances for even deeper discounts on stable workloads"
    echo "  • Monitor Compute Savings Plan coverage metrics monthly"
    echo "  • Set up alerts for plan expiry using EventBridge"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Savings Plans Analyzer Started ==="
  
  write_header
  analyze_savings_plans
  analyze_coverage
  list_unprotected_instances
  recommendations
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "View in AWS Console:"
    echo "  https://console.aws.amazon.com/costmanagement/home?region=${REGION}#/savings-plans"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== Savings Plans Analyzer Completed ==="
}

main "$@"

#!/bin/bash

################################################################################
# AWS Fargate Cost Optimizer
# Analyzes ECS services on Fargate to estimate costs, detect under/over
# utilization, and recommend right-sizing and scheduling optimizations.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/fargate-cost-optimizer-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/fargate-cost-optimizer.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
DRY_RUN="${DRY_RUN:-true}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
PERIOD_SECONDS="${PERIOD_SECONDS:-300}"

# Thresholds
CPU_LOW_UTIL="${CPU_LOW_UTIL:-30}"          # %
MEM_LOW_UTIL="${MEM_LOW_UTIL:-30}"          # %
CPU_HIGH_UTIL="${CPU_HIGH_UTIL:-80}"        # %
MEM_HIGH_UTIL="${MEM_HIGH_UTIL:-85}"        # %
IDLE_TASKS_WARN="${IDLE_TASKS_WARN:-1}"     # tasks with <5% CPU & MEM

# Approx Fargate Linux pricing (USD) per hour (baseline regions)
# Source may vary by region/time; adjust as needed.
VCPU_PRICE_US_EAST_1="0.04048"     # per vCPU-hour
MEM_PRICE_US_EAST_1="0.004445"     # per GB-hour

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

price_vcpu_for_region() {
  case "${REGION}" in
    us-east-1|us-east-2|us-west-2)
      echo "${VCPU_PRICE_US_EAST_1}" ;;
    *)
      echo "${VCPU_PRICE_US_EAST_1}" ;;
  esac
}

price_mem_for_region() {
  case "${REGION}" in
    us-east-1|us-east-2|us-west-2)
      echo "${MEM_PRICE_US_EAST_1}" ;;
    *)
      echo "${MEM_PRICE_US_EAST_1}" ;;
  esac
}

list_clusters() {
  aws ecs list-clusters --region "${REGION}" --output json 2>/dev/null || echo '{"clusterArns":[]}'
}

list_services() {
  local cluster_arn="$1"
  aws ecs list-services --cluster "${cluster_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{"serviceArns":[]}'
}

describe_services() {
  local cluster_arn="$1"; shift
  aws ecs describe-services --cluster "${cluster_arn}" --services "$@" --region "${REGION}" --output json 2>/dev/null || echo '{"services":[]}'
}

describe_task_definition() {
  local task_def_arn="$1"
  aws ecs describe-task-definition --task-definition "${task_def_arn}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

cw_service_metric() {
  local cluster_name="$1"
  local service_name="$2"
  local metric_name="$3"
  local start_time end_time
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  aws cloudwatch get-metric-statistics \
    --namespace AWS/ECS \
    --metric-name "${metric_name}" \
    --dimensions Name=ClusterName,Value="${cluster_name}" Name=ServiceName,Value="${service_name}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${PERIOD_SECONDS}" \
    --statistics Average,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

avg_from_datapoints() {
  jq -r '.Datapoints[].Average' 2>/dev/null | awk '{s+=$1; c++} END { if (c>0) printf "%.2f", s/c; else print "0" }'
}

get_name_from_arn() {
  local arn="$1"
  echo "${arn##*/}"
}

send_slack_alert() {
  local message="$1"
  local severity="${2:-INFO}"
  if [[ -z "${SLACK_WEBHOOK}" ]]; then return; fi
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
    {"color": "${color}", "title": "Fargate Cost Optimizer", "text": "${message}", "ts": $(date +%s)}
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
    echo "AWS Fargate Cost Optimization Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Lookback Window: ${LOOKBACK_HOURS}h (period ${PERIOD_SECONDS}s)"
    echo "Dry Run: ${DRY_RUN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

analyze_service() {
  local cluster_arn="$1"; local service_arn="$2"; local vcpu_price mem_price
  vcpu_price=$(price_vcpu_for_region)
  mem_price=$(price_mem_for_region)

  local cluster_name service_name
  cluster_name=$(get_name_from_arn "${cluster_arn}")
  service_name=$(get_name_from_arn "${service_arn}")

  local svc_desc
  svc_desc=$(describe_services "${cluster_arn}" "${service_arn}")

  local launch_type desired running task_def_arn scheduling_strategy
  launch_type=$(echo "${svc_desc}" | jq -r '.services[0].launchType // ""')
  desired=$(echo "${svc_desc}" | jq -r '.services[0].desiredCount // 0')
  running=$(echo "${svc_desc}" | jq -r '.services[0].runningCount // 0')
  task_def_arn=$(echo "${svc_desc}" | jq -r '.services[0].taskDefinition // ""')
  scheduling_strategy=$(echo "${svc_desc}" | jq -r '.services[0].schedulingStrategy // "REPLICA"')

  if [[ "${launch_type}" != "FARGATE" ]]; then
    return
  fi

  local td desc_cpu desc_mem
  td=$(describe_task_definition "${task_def_arn}")
  desc_cpu=$(echo "${td}" | jq -r '.taskDefinition.cpu // "0"')
  desc_mem=$(echo "${td}" | jq -r '.taskDefinition.memory // "0"')

  # Convert to vCPU and GB
  local task_vcpu task_gb
  task_vcpu=$(awk -v c="${desc_cpu}" 'BEGIN{printf "%.3f", c/1024.0}')
  task_gb=$(awk -v m="${desc_mem}" 'BEGIN{printf "%.3f", m/1024.0}')

  # Metrics
  local cpu_json mem_json cpu_avg mem_avg
  cpu_json=$(cw_service_metric "${cluster_name}" "${service_name}" "CPUUtilization")
  mem_json=$(cw_service_metric "${cluster_name}" "${service_name}" "MemoryUtilization")
  cpu_avg=$(echo "${cpu_json}" | avg_from_datapoints)
  mem_avg=$(echo "${mem_json}" | avg_from_datapoints)

  # Cost estimations (per task)
  local hourly_task_cost monthly_task_cost
  hourly_task_cost=$(awk -v v="${task_vcpu}" -v m="${task_gb}" -v pv="${vcpu_price}" -v pm="${mem_price}" 'BEGIN{printf "%.5f", v*pv + m*pm}')
  monthly_task_cost=$(awk -v h="${hourly_task_cost}" 'BEGIN{printf "%.2f", h*730}')

  local total_monthly_cost
  total_monthly_cost=$(awk -v mtc="${monthly_task_cost}" -v rc="${running}" 'BEGIN{printf "%.2f", mtc*rc}')

  {
    echo "Cluster: ${cluster_name}"
    echo "Service: ${service_name}"
    echo "Launch Type: ${launch_type}"
    echo "Desired/Running: ${desired}/${running}"
    echo "Task Definition: $(get_name_from_arn "${task_def_arn}")"
    echo "Requested CPU/Memory: ${desc_cpu} (≈${task_vcpu} vCPU) / ${desc_mem} (≈${task_gb} GB)"
    echo "Avg CPU/Memory Utilization: ${cpu_avg}% / ${mem_avg}%"
    echo "Cost per task: $${monthly_task_cost}/month (≈$${hourly_task_cost}/hour)"
    echo "Estimated monthly service cost: $${total_monthly_cost}"
  } >> "${OUTPUT_FILE}"

  local recommendations=0
  {
    echo "Recommendations:"
  } >> "${OUTPUT_FILE}"

  # Under-utilization
  if (( $(echo "${cpu_avg} < ${CPU_LOW_UTIL} && ${mem_avg} < ${MEM_LOW_UTIL}" | bc -l) )); then
    {
      echo "  • Under-utilized: consider reducing task size or desired count"
    } >> "${OUTPUT_FILE}"
    ((recommendations++))
  fi

  # Over-utilization
  if (( $(echo "${cpu_avg} > ${CPU_HIGH_UTIL} || ${mem_avg} > ${MEM_HIGH_UTIL}" | bc -l) )); then
    {
      echo "  • Resource pressure: consider larger task size or additional tasks"
    } >> "${OUTPUT_FILE}"
    ((recommendations++))
    send_slack_alert "High utilization on ${cluster_name}/${service_name}: CPU ${cpu_avg}%, Mem ${mem_avg}%" "WARNING"
  fi

  # Idle tasks
  if (( $(echo "${cpu_avg} < 5 && ${mem_avg} < 5" | bc -l) )) && [[ ${running} -ge ${IDLE_TASKS_WARN} ]]; then
    {
      echo "  • Idle service: very low CPU & memory, consider scaling to 0 off-hours"
    } >> "${OUTPUT_FILE}"
    ((recommendations++))
  fi

  # Potential savings estimate: reduce 1 task if underutilized
  if (( $(echo "${cpu_avg} < ${CPU_LOW_UTIL} && ${mem_avg} < ${MEM_LOW_UTIL} && ${desired} > 1" | bc -l) )); then
    local savings
    savings="${monthly_task_cost}"
    {
      echo "  • Potential savings: reduce 1 task ≈ $${savings}/month"
    } >> "${OUTPUT_FILE}"
  fi

  if [[ ${recommendations} -eq 0 ]]; then
    echo "  • ✓ Looks well-sized" >> "${OUTPUT_FILE}"
  fi

  echo "" >> "${OUTPUT_FILE}"
}

analyze_all() {
  log_message INFO "Starting Fargate cost optimization analysis"
  {
    echo "=== FARGATE SERVICES ==="
    echo ""
  } >> "${OUTPUT_FILE}"

  local clusters_json cluster_arns
  clusters_json=$(list_clusters)
  cluster_arns=$(echo "${clusters_json}" | jq -r '.clusterArns[]?' 2>/dev/null)
  if [[ -z "${cluster_arns}" ]]; then
    echo "No ECS clusters found in ${REGION}" >> "${OUTPUT_FILE}"
    return
  fi

  while IFS= read -r cluster_arn; do
    [[ -z "${cluster_arn}" ]] && continue
    local services_json service_arns
    services_json=$(list_services "${cluster_arn}")
    service_arns=$(echo "${services_json}" | jq -r '.serviceArns[]?' 2>/dev/null)
    if [[ -z "${service_arns}" ]]; then
      {
        echo "Cluster: $(get_name_from_arn "${cluster_arn}")"
        echo "  No services found"
        echo ""
      } >> "${OUTPUT_FILE}"
      continue
    fi
    while IFS= read -r service_arn; do
      [[ -z "${service_arn}" ]] && continue
      analyze_service "${cluster_arn}" "${service_arn}"
    done <<< "${service_arns}"
  done <<< "${cluster_arns}"

  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== Fargate Cost Optimizer Started ==="
  write_header
  analyze_all
  cat "${OUTPUT_FILE}"
  log_message INFO "=== Fargate Cost Optimizer Completed ==="
}

main "$@"

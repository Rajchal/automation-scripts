#!/bin/bash

################################################################################
# AWS ECS Cluster Health Monitor
# Monitors ECS clusters, services, tasks, container insights metrics, and
# provides alerts for deployment failures and performance issues.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ecs-cluster-health-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/ecs-cluster-health.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
CPU_WARN_PCT="${CPU_WARN_PCT:-80}"                  # CPU utilization warning
MEMORY_WARN_PCT="${MEMORY_WARN_PCT:-80}"            # Memory utilization warning
TASK_FAILURE_THRESHOLD="${TASK_FAILURE_THRESHOLD:-5}" # Failed task count
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_CLUSTERS=0
TOTAL_SERVICES=0
TOTAL_TASKS=0
UNHEALTHY_SERVICES=0
HIGH_CPU_SERVICES=0
HIGH_MEMORY_SERVICES=0
FAILED_TASKS=0
DEPLOYMENT_FAILURES=0

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
      "title": "ECS Cluster Alert",
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
    echo "AWS ECS Cluster Health Monitor"
    echo "==============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  CPU Warning: ${CPU_WARN_PCT}%"
    echo "  Memory Warning: ${MEMORY_WARN_PCT}%"
    echo "  Task Failure Threshold: ${TASK_FAILURE_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws ecs list-clusters \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"clusterArns":[]}'
}

describe_clusters() {
  local cluster_arns="$1"
  aws ecs describe-clusters \
    --clusters ${cluster_arns} \
    --include STATISTICS TAGS \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"clusters":[]}'
}

list_services() {
  local cluster="$1"
  aws ecs list-services \
    --cluster "${cluster}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"serviceArns":[]}'
}

describe_services() {
  local cluster="$1"
  local service_arns="$2"
  aws ecs describe-services \
    --cluster "${cluster}" \
    --services ${service_arns} \
    --include TAGS \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"services":[]}'
}

list_tasks() {
  local cluster="$1"
  local service_name="$2"
  aws ecs list-tasks \
    --cluster "${cluster}" \
    --service-name "${service_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"taskArns":[]}'
}

describe_tasks() {
  local cluster="$1"
  local task_arns="$2"
  aws ecs describe-tasks \
    --cluster "${cluster}" \
    --tasks ${task_arns} \
    --include TAGS \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"tasks":[]}'
}

list_container_instances() {
  local cluster="$1"
  aws ecs list-container-instances \
    --cluster "${cluster}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"containerInstanceArns":[]}'
}

describe_container_instances() {
  local cluster="$1"
  local instance_arns="$2"
  aws ecs describe-container-instances \
    --cluster "${cluster}" \
    --container-instances ${instance_arns} \
    --include TAGS \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"containerInstances":[]}'
}

get_ecs_metrics() {
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
    awk 'BEGIN {max=0} {if ($1>max) max=$1} END {printf "%.2f", max}'
}

monitor_clusters() {
  log_message INFO "Starting ECS cluster monitoring"
  
  {
    echo "=== ECS CLUSTER INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local clusters_json
  clusters_json=$(list_clusters)
  
  local cluster_arns
  cluster_arns=$(echo "${clusters_json}" | jq -r '.clusterArns[]' 2>/dev/null)
  
  if [[ -z "${cluster_arns}" ]]; then
    {
      echo "No ECS clusters found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Describe all clusters at once
  local clusters_detail
  clusters_detail=$(describe_clusters "${cluster_arns}")
  
  local cluster_count
  cluster_count=$(echo "${clusters_detail}" | jq '.clusters | length' 2>/dev/null || echo "0")
  
  TOTAL_CLUSTERS=${cluster_count}
  
  {
    echo "Total Clusters: ${cluster_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local clusters
  clusters=$(echo "${clusters_detail}" | jq -c '.clusters[]' 2>/dev/null)
  
  while IFS= read -r cluster; do
    [[ -z "${cluster}" ]] && continue
    
    local cluster_name cluster_arn status
    cluster_name=$(echo "${cluster}" | jq_safe '.clusterName')
    cluster_arn=$(echo "${cluster}" | jq_safe '.clusterArn')
    status=$(echo "${cluster}" | jq_safe '.status')
    
    log_message INFO "Analyzing cluster: ${cluster_name}"
    
    {
      echo "=== CLUSTER: ${cluster_name} ==="
      echo ""
      echo "ARN: ${cluster_arn}"
      echo "Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    # Cluster statistics
    analyze_cluster_stats "${cluster}" "${cluster_name}"
    
    # Container instances (EC2 launch type)
    analyze_container_instances "${cluster_name}"
    
    # Services
    monitor_services "${cluster_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${clusters}"
}

analyze_cluster_stats() {
  local cluster="$1"
  local cluster_name="$2"
  
  local registered_instances active_services running_tasks pending_tasks
  registered_instances=$(echo "${cluster}" | jq_safe '.registeredContainerInstancesCount // 0')
  active_services=$(echo "${cluster}" | jq_safe '.activeServicesCount // 0')
  running_tasks=$(echo "${cluster}" | jq_safe '.runningTasksCount // 0')
  pending_tasks=$(echo "${cluster}" | jq_safe '.pendingTasksCount // 0')
  
  {
    echo "Statistics:"
    echo "  Container Instances: ${registered_instances}"
    echo "  Active Services: ${active_services}"
    echo "  Running Tasks: ${running_tasks}"
    echo "  Pending Tasks: ${pending_tasks}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${pending_tasks} -gt 10 ]]; then
    {
      printf "  %b⚠️  High number of pending tasks%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Cluster ${cluster_name} has ${pending_tasks} pending tasks"
  fi
  
  # Check capacity providers
  local capacity_providers
  capacity_providers=$(echo "${cluster}" | jq -r '.capacityProviders[]?' 2>/dev/null)
  
  if [[ -n "${capacity_providers}" ]]; then
    {
      echo "  Capacity Providers:"
    } >> "${OUTPUT_FILE}"
    
    while IFS= read -r provider; do
      [[ -z "${provider}" ]] && continue
      {
        echo "    - ${provider}"
      } >> "${OUTPUT_FILE}"
    done <<< "${capacity_providers}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_container_instances() {
  local cluster_name="$1"
  
  {
    echo "Container Instances (EC2 Launch Type):"
  } >> "${OUTPUT_FILE}"
  
  local instances_json
  instances_json=$(list_container_instances "${cluster_name}")
  
  local instance_arns
  instance_arns=$(echo "${instances_json}" | jq -r '.containerInstanceArns[]' 2>/dev/null)
  
  if [[ -z "${instance_arns}" ]]; then
    {
      echo "  No EC2 container instances (likely using Fargate)"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local instances_detail
  instances_detail=$(describe_container_instances "${cluster_name}" "${instance_arns}")
  
  local instance_count
  instance_count=$(echo "${instances_detail}" | jq '.containerInstances | length' 2>/dev/null || echo "0")
  
  {
    echo "  Count: ${instance_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local instances
  instances=$(echo "${instances_detail}" | jq -c '.containerInstances[]' 2>/dev/null)
  
  while IFS= read -r instance; do
    [[ -z "${instance}" ]] && continue
    
    local ec2_id status running_tasks
    ec2_id=$(echo "${instance}" | jq_safe '.ec2InstanceId')
    status=$(echo "${instance}" | jq_safe '.status')
    running_tasks=$(echo "${instance}" | jq_safe '.runningTasksCount // 0')
    
    {
      echo "  Instance: ${ec2_id}"
      echo "    Status: ${status}"
      echo "    Running Tasks: ${running_tasks}"
    } >> "${OUTPUT_FILE}"
    
    # Check remaining resources
    local remaining_cpu remaining_memory
    remaining_cpu=$(echo "${instance}" | jq -r '.remainingResources[] | select(.name == "CPU") | .integerValue' 2>/dev/null || echo "0")
    remaining_memory=$(echo "${instance}" | jq -r '.remainingResources[] | select(.name == "MEMORY") | .integerValue' 2>/dev/null || echo "0")
    
    {
      echo "    Remaining CPU: ${remaining_cpu}"
      echo "    Remaining Memory: ${remaining_memory} MB"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${status}" == "ACTIVE" ]]; then
      {
        printf "    %b✓ Instance Active%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "    %b⚠️  Instance Status: %s%b\n" "${YELLOW}" "${status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Container instance ${ec2_id} status: ${status}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${instances}"
}

monitor_services() {
  local cluster_name="$1"
  
  {
    echo "Services:"
  } >> "${OUTPUT_FILE}"
  
  local services_json
  services_json=$(list_services "${cluster_name}")
  
  local service_arns
  service_arns=$(echo "${services_json}" | jq -r '.serviceArns[]' 2>/dev/null)
  
  if [[ -z "${service_arns}" ]]; then
    {
      echo "  No services found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local services_detail
  services_detail=$(describe_services "${cluster_name}" "${service_arns}")
  
  local service_count
  service_count=$(echo "${services_detail}" | jq '.services | length' 2>/dev/null || echo "0")
  
  TOTAL_SERVICES=$((TOTAL_SERVICES + service_count))
  
  {
    echo "  Count: ${service_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local services
  services=$(echo "${services_detail}" | jq -c '.services[]' 2>/dev/null)
  
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    
    local service_name service_arn status
    service_name=$(echo "${service}" | jq_safe '.serviceName')
    service_arn=$(echo "${service}" | jq_safe '.serviceArn')
    status=$(echo "${service}" | jq_safe '.status')
    
    log_message INFO "Analyzing service: ${service_name}"
    
    {
      echo "  Service: ${service_name}"
      echo "    Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    # Task counts
    analyze_service_tasks "${service}" "${cluster_name}" "${service_name}"
    
    # Deployment status
    analyze_deployments "${service}" "${service_name}"
    
    # Events
    get_service_events "${service}" "${service_name}"
    
    # Load balancer
    check_load_balancer "${service}"
    
    # Auto-scaling
    check_auto_scaling "${service}"
    
    # CloudWatch metrics
    analyze_service_metrics "${cluster_name}" "${service_name}"
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${services}"
}

analyze_service_tasks() {
  local service="$1"
  local cluster_name="$2"
  local service_name="$3"
  
  local desired running pending
  desired=$(echo "${service}" | jq_safe '.desiredCount // 0')
  running=$(echo "${service}" | jq_safe '.runningCount // 0')
  pending=$(echo "${service}" | jq_safe '.pendingCount // 0')
  
  TOTAL_TASKS=$((TOTAL_TASKS + running + pending))
  
  {
    echo "    Tasks:"
    echo "      Desired: ${desired}"
    echo "      Running: ${running}"
    echo "      Pending: ${pending}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${running} -lt ${desired} ]]; then
    ((UNHEALTHY_SERVICES++))
    {
      printf "      %b⚠️  Running tasks below desired count%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Service ${service_name} has ${running}/${desired} tasks running"
  elif [[ ${running} -eq ${desired} ]]; then
    {
      printf "      %b✓ Task count healthy%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Launch type
  local launch_type
  launch_type=$(echo "${service}" | jq_safe '.launchType // "UNKNOWN"')
  
  {
    echo "      Launch Type: ${launch_type}"
  } >> "${OUTPUT_FILE}"
}

analyze_deployments() {
  local service="$1"
  local service_name="$2"
  
  {
    echo "    Deployments:"
  } >> "${OUTPUT_FILE}"
  
  local deployments
  deployments=$(echo "${service}" | jq -c '.deployments[]' 2>/dev/null)
  
  if [[ -z "${deployments}" ]]; then
    {
      echo "      No active deployments"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local deployment_count
  deployment_count=$(echo "${service}" | jq '.deployments | length' 2>/dev/null || echo "0")
  
  {
    echo "      Active Deployments: ${deployment_count}"
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r deployment; do
    [[ -z "${deployment}" ]] && continue
    
    local deployment_id deployment_status created_at task_definition
    deployment_id=$(echo "${deployment}" | jq_safe '.id')
    deployment_status=$(echo "${deployment}" | jq_safe '.status')
    created_at=$(echo "${deployment}" | jq_safe '.createdAt')
    task_definition=$(echo "${deployment}" | jq_safe '.taskDefinition' | awk -F'/' '{print $NF}')
    
    {
      echo "      Deployment ID: ${deployment_id}"
      echo "        Status: ${deployment_status}"
      echo "        Task Definition: ${task_definition}"
      echo "        Created: ${created_at}"
    } >> "${OUTPUT_FILE}"
    
    local desired running pending failed
    desired=$(echo "${deployment}" | jq_safe '.desiredCount // 0')
    running=$(echo "${deployment}" | jq_safe '.runningCount // 0')
    pending=$(echo "${deployment}" | jq_safe '.pendingCount // 0')
    failed=$(echo "${deployment}" | jq_safe '.failedTasks // 0')
    
    {
      echo "        Desired: ${desired}, Running: ${running}, Pending: ${pending}, Failed: ${failed}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${deployment_status}" == "PRIMARY" && ${running} -eq ${desired} ]]; then
      {
        printf "        %b✓ Deployment successful%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    elif [[ "${deployment_status}" == "ACTIVE" ]]; then
      {
        printf "        %b⚙️  Deployment in progress%b\n" "${CYAN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    elif [[ ${failed} -gt 0 ]]; then
      ((DEPLOYMENT_FAILURES++))
      FAILED_TASKS=$((FAILED_TASKS + failed))
      {
        printf "        %b⚠️  Deployment has failed tasks%b\n" "${RED}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message ERROR "Service ${service_name} deployment has ${failed} failed tasks"
    fi
    
  done <<< "${deployments}"
}

get_service_events() {
  local service="$1"
  local service_name="$2"
  
  {
    echo "    Recent Events:"
  } >> "${OUTPUT_FILE}"
  
  local events
  events=$(echo "${service}" | jq -c '.events[]' 2>/dev/null | head -5)
  
  if [[ -z "${events}" ]]; then
    {
      echo "      No recent events"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS= read -r event; do
    [[ -z "${event}" ]] && continue
    
    local created_at message
    created_at=$(echo "${event}" | jq_safe '.createdAt')
    message=$(echo "${event}" | jq_safe '.message')
    
    {
      echo "      ${created_at}: ${message}"
    } >> "${OUTPUT_FILE}"
    
  done <<< "${events}"
}

check_load_balancer() {
  local service="$1"
  
  local load_balancers
  load_balancers=$(echo "${service}" | jq -c '.loadBalancers[]?' 2>/dev/null)
  
  if [[ -z "${load_balancers}" ]]; then
    {
      echo "    Load Balancer: None configured"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "    Load Balancers:"
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r lb; do
    [[ -z "${lb}" ]] && continue
    
    local target_group container_name container_port
    target_group=$(echo "${lb}" | jq_safe '.targetGroupArn' | awk -F':' '{print $NF}')
    container_name=$(echo "${lb}" | jq_safe '.containerName')
    container_port=$(echo "${lb}" | jq_safe '.containerPort')
    
    {
      echo "      - Target Group: ${target_group}"
      echo "        Container: ${container_name}:${container_port}"
    } >> "${OUTPUT_FILE}"
    
  done <<< "${load_balancers}"
}

check_auto_scaling() {
  local service="$1"
  
  local scheduling_strategy
  scheduling_strategy=$(echo "${service}" | jq_safe '.schedulingStrategy // "REPLICA"')
  
  {
    echo "    Scheduling Strategy: ${scheduling_strategy}"
  } >> "${OUTPUT_FILE}"
  
  # Note: Auto-scaling policies are managed by Application Auto Scaling
  # Would require additional API calls to get detailed scaling policies
}

analyze_service_metrics() {
  local cluster_name="$1"
  local service_name="$2"
  
  {
    echo "    Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # CPU Utilization
  local cpu_json
  cpu_json=$(get_ecs_metrics "${cluster_name}" "${service_name}" "CPUUtilization")
  
  local avg_cpu max_cpu
  avg_cpu=$(echo "${cpu_json}" | calculate_avg)
  max_cpu=$(echo "${cpu_json}" | calculate_max)
  
  {
    echo "      CPU Utilization:"
    echo "        Average: ${avg_cpu}%"
    echo "        Maximum: ${max_cpu}%"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_cpu} > ${CPU_WARN_PCT}" | bc -l 2>/dev/null || echo "0") )); then
    ((HIGH_CPU_SERVICES++))
    {
      printf "        %b⚠️  High CPU utilization%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Service ${service_name} avg CPU: ${avg_cpu}%"
  fi
  
  # Memory Utilization
  local memory_json
  memory_json=$(get_ecs_metrics "${cluster_name}" "${service_name}" "MemoryUtilization")
  
  local avg_memory max_memory
  avg_memory=$(echo "${memory_json}" | calculate_avg)
  max_memory=$(echo "${memory_json}" | calculate_max)
  
  {
    echo "      Memory Utilization:"
    echo "        Average: ${avg_memory}%"
    echo "        Maximum: ${max_memory}%"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_memory} > ${MEMORY_WARN_PCT}" | bc -l 2>/dev/null || echo "0") )); then
    ((HIGH_MEMORY_SERVICES++))
    {
      printf "        %b⚠️  High memory utilization%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Service ${service_name} avg memory: ${avg_memory}%"
  fi
}

generate_summary() {
  {
    echo ""
    echo "=== ECS CLUSTER SUMMARY ==="
    echo ""
    printf "Total Clusters: %d\n" "${TOTAL_CLUSTERS}"
    printf "Total Services: %d\n" "${TOTAL_SERVICES}"
    printf "Total Tasks: %d\n" "${TOTAL_TASKS}"
    echo ""
    printf "Unhealthy Services: %d\n" "${UNHEALTHY_SERVICES}"
    printf "High CPU Services: %d\n" "${HIGH_CPU_SERVICES}"
    printf "High Memory Services: %d\n" "${HIGH_MEMORY_SERVICES}"
    printf "Deployment Failures: %d\n" "${DEPLOYMENT_FAILURES}"
    printf "Failed Tasks: %d\n" "${FAILED_TASKS}"
    echo ""
    
    if [[ ${DEPLOYMENT_FAILURES} -gt 0 ]] || [[ ${FAILED_TASKS} -gt ${TASK_FAILURE_THRESHOLD} ]]; then
      printf "%b[CRITICAL] Deployment or task failures detected%b\n" "${RED}" "${NC}"
    elif [[ ${UNHEALTHY_SERVICES} -gt 0 ]] || [[ ${HIGH_CPU_SERVICES} -gt 0 ]] || [[ ${HIGH_MEMORY_SERVICES} -gt 0 ]]; then
      printf "%b[WARNING] Service health or performance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All ECS clusters operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${UNHEALTHY_SERVICES} -gt 0 ]]; then
      echo "Unhealthy Service Remediation:"
      echo "  • Check service events for deployment issues"
      echo "  • Verify task definition health checks"
      echo "  • Review container logs in CloudWatch"
      echo "  • Check security group and network configuration"
      echo "  • Verify IAM task role permissions"
      echo "  • Check if cluster has sufficient capacity"
      echo "  • Review service discovery configuration"
      echo ""
    fi
    
    if [[ ${DEPLOYMENT_FAILURES} -gt 0 ]]; then
      echo "Deployment Failure Recovery:"
      echo "  • Review failed task stopped reason"
      echo "  • Check container image availability"
      echo "  • Verify environment variables and secrets"
      echo "  • Review deployment circuit breaker configuration"
      echo "  • Check task definition resource limits"
      echo "  • Verify load balancer health check settings"
      echo "  • Enable deployment rollback for safety"
      echo ""
    fi
    
    if [[ ${HIGH_CPU_SERVICES} -gt 0 ]] || [[ ${HIGH_MEMORY_SERVICES} -gt 0 ]]; then
      echo "Resource Optimization:"
      echo "  • Review task definition CPU/memory allocation"
      echo "  • Enable Container Insights for detailed metrics"
      echo "  • Implement auto-scaling based on utilization"
      echo "  • Optimize application code for efficiency"
      echo "  • Consider using larger instance types (EC2)"
      echo "  • Review container startup time and dependencies"
      echo "  • Use AWS Compute Optimizer recommendations"
      echo ""
    fi
    
    echo "High Availability Best Practices:"
    echo "  • Run minimum 2 tasks per service"
    echo "  • Deploy across multiple AZs"
    echo "  • Use Application Load Balancer for traffic distribution"
    echo "  • Configure health checks properly"
    echo "  • Enable deployment circuit breaker"
    echo "  • Set appropriate deregistration delay"
    echo "  • Use service discovery for dynamic endpoints"
    echo "  • Implement graceful shutdown handling"
    echo ""
    
    echo "Performance Optimization:"
    echo "  • Enable Container Insights for observability"
    echo "  • Use AWS X-Ray for distributed tracing"
    echo "  • Optimize container image size (multi-stage builds)"
    echo "  • Use ECR image scanning for vulnerabilities"
    echo "  • Implement caching strategies"
    echo "  • Configure appropriate task placement strategies"
    echo "  • Use Fargate Spot for cost savings on fault-tolerant workloads"
    echo "  • Enable ECS Exec for debugging running containers"
    echo ""
    
    echo "Security Hardening:"
    echo "  • Use IAM task roles with least privilege"
    echo "  • Enable secrets management (Secrets Manager/Parameter Store)"
    echo "  • Use private subnets with NAT gateway"
    echo "  • Enable VPC Flow Logs"
    echo "  • Implement network segmentation with security groups"
    echo "  • Use ECR image scanning and signed images"
    echo "  • Enable GuardDuty for threat detection"
    echo "  • Rotate credentials regularly"
    echo ""
    
    echo "Monitoring & Alerting:"
    echo "  • CloudWatch alarms on CPU/Memory utilization"
    echo "  • Monitor deployment status changes"
    echo "  • Alert on task stopped events"
    echo "  • Track service desired vs running count"
    echo "  • Monitor load balancer target health"
    echo "  • Use CloudWatch Logs Insights for log analysis"
    echo "  • Enable EventBridge rules for ECS events"
    echo "  • Integrate with SNS for notifications"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • Use Fargate Spot for up to 70% savings"
    echo "  • Right-size task definitions (CPU/memory)"
    echo "  • Use Savings Plans or Reserved Instances (EC2)"
    echo "  • Enable auto-scaling to match demand"
    echo "  • Delete unused task definitions"
    echo "  • Use AWS Cost Explorer to analyze ECS costs"
    echo "  • Consider Graviton2 (ARM) for better price/performance"
    echo "  • Stop non-production services outside business hours"
    echo ""
    
    echo "Deployment Strategies:"
    echo "  • Use rolling updates for zero-downtime deployments"
    echo "  • Configure deployment circuit breaker for auto-rollback"
    echo "  • Set appropriate minimum healthy percent (e.g., 100%)"
    echo "  • Set maximum percent (e.g., 200%) for faster deployments"
    echo "  • Use blue/green deployments via CodeDeploy"
    echo "  • Implement canary deployments for risk mitigation"
    echo "  • Test in staging before production"
    echo ""
    
    echo "Capacity Planning:"
    echo "  • Monitor cluster CPU/memory reservation"
    echo "  • Use capacity providers for automatic scaling"
    echo "  • Configure target tracking scaling policies"
    echo "  • Set appropriate scale-in protection"
    echo "  • Review task placement constraints"
    echo "  • Plan for peak traffic scenarios"
    echo "  • Use EC2 Auto Scaling for cluster capacity"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== ECS Cluster Health Monitor Started ==="
  
  write_header
  monitor_clusters
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS ECS Documentation:"
    echo "  https://docs.aws.amazon.com/ecs/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== ECS Cluster Health Monitor Completed ==="
  
  # Send alerts
  if [[ ${DEPLOYMENT_FAILURES} -gt 0 ]] || [[ ${FAILED_TASKS} -gt ${TASK_FAILURE_THRESHOLD} ]]; then
    send_slack_alert "🚨 ECS deployment failures: ${DEPLOYMENT_FAILURES} deployments, ${FAILED_TASKS} failed tasks" "CRITICAL"
    send_email_alert "ECS Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${UNHEALTHY_SERVICES} -gt 0 ]]; then
    send_slack_alert "⚠️ ${UNHEALTHY_SERVICES} ECS service(s) unhealthy" "WARNING"
  fi
}

main "$@"

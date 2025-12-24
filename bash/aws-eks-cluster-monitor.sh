#!/bin/bash

################################################################################
# AWS EKS Cluster Monitor
# Monitors EKS clusters for node health, pod restarts, API server latency,
# HPA status, control plane logs, and cluster add-ons.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/eks-cluster-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/eks-cluster-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
API_LATENCY_WARN_MS="${API_LATENCY_WARN_MS:-500}"    # milliseconds
NODE_NOT_READY_WARN="${NODE_NOT_READY_WARN:-1}"      # count
POD_RESTART_WARN="${POD_RESTART_WARN:-10}"           # restart count
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
TOTAL_NODES=0
UNHEALTHY_NODES=0
HIGH_POD_RESTARTS=0
FAILED_ADDONS=0
FAILED_HPAS=0
HIGH_API_LATENCY=0

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
      "title": "EKS Cluster Alert",
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
    echo "AWS EKS Cluster Monitor"
    echo "======================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  API Latency Warning: ${API_LATENCY_WARN_MS}ms"
    echo "  Not Ready Nodes Warning: ${NODE_NOT_READY_WARN}"
    echo "  Pod Restart Warning: ${POD_RESTART_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_clusters() {
  aws eks list-clusters \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"clusters":[]}'
}

describe_cluster() {
  local cluster_name="$1"
  aws eks describe-cluster \
    --name "${cluster_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_nodegroups() {
  local cluster_name="$1"
  aws eks list-nodegroups \
    --cluster-name "${cluster_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"nodegroups":[]}'
}

describe_nodegroup() {
  local cluster_name="$1"
  local nodegroup_name="$2"
  aws eks describe-nodegroup \
    --cluster-name "${cluster_name}" \
    --nodegroup-name "${nodegroup_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_addons() {
  local cluster_name="$1"
  aws eks list-addons \
    --cluster-name "${cluster_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"addons":[]}'
}

describe_addon() {
  local cluster_name="$1"
  local addon_name="$2"
  aws eks describe-addon \
    --cluster-name "${cluster_name}" \
    --addon-name "${addon_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_cluster_logs() {
  local cluster_name="$1"
  local log_types=("api" "audit" "authenticator" "controllerManager" "scheduler")
  
  for log_type in "${log_types[@]}"; do
    aws eks describe-cluster \
      --name "${cluster_name}" \
      --query "cluster.logging.clusterLogging[?types[?@=='${log_type}']]" \
      --region "${REGION}" \
      --output json 2>/dev/null || true
  done
}

get_cluster_metrics() {
  local cluster_name="$1"
  local metric_name="$2"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EKS \
    --metric-name "${metric_name}" \
    --dimensions Name=ClusterName,Value="${cluster_name}" \
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
  log_message INFO "Starting EKS cluster monitoring"
  
  {
    echo "=== EKS CLUSTER INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local clusters_json
  clusters_json=$(list_clusters)
  
  local cluster_names
  cluster_names=$(echo "${clusters_json}" | jq -r '.clusters[]' 2>/dev/null)
  
  if [[ -z "${cluster_names}" ]]; then
    {
      echo "No EKS clusters found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local cluster_count
  cluster_count=$(echo "${cluster_names}" | wc -l)
  
  TOTAL_CLUSTERS=${cluster_count}
  
  {
    echo "Total Clusters: ${cluster_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r cluster_name; do
    [[ -z "${cluster_name}" ]] && continue
    
    log_message INFO "Analyzing cluster: ${cluster_name}"
    
    analyze_cluster "${cluster_name}"
    
  done <<< "${cluster_names}"
}

analyze_cluster() {
  local cluster_name="$1"
  
  {
    echo "=== CLUSTER: ${cluster_name} ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local cluster_detail
  cluster_detail=$(describe_cluster "${cluster_name}")
  
  local cluster_status cluster_arn version endpoint
  cluster_status=$(echo "${cluster_detail}" | jq_safe '.cluster.status')
  cluster_arn=$(echo "${cluster_detail}" | jq_safe '.cluster.arn')
  version=$(echo "${cluster_detail}" | jq_safe '.cluster.version')
  endpoint=$(echo "${cluster_detail}" | jq_safe '.cluster.endpoint')
  
  {
    echo "Status: ${cluster_status}"
    echo "Version: ${version}"
    echo "Endpoint: ${endpoint}"
    echo "ARN: ${cluster_arn}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${cluster_status}" != "ACTIVE" ]]; then
    {
      printf "%b⚠️  Cluster Status: %s%b\n" "${YELLOW}" "${cluster_status}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Cluster ${cluster_name} status: ${cluster_status}"
  else
    {
      printf "%b✓ Cluster Active%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
  
  # Check API latency
  analyze_api_metrics "${cluster_name}"
  
  # Check cluster add-ons
  check_addons "${cluster_name}"
  
  # Check node groups
  monitor_nodegroups "${cluster_name}"
  
  # Check logging
  check_logging "${cluster_detail}" "${cluster_name}"
  
  {
    echo "---"
    echo ""
  } >> "${OUTPUT_FILE}"
}

analyze_api_metrics() {
  local cluster_name="$1"
  
  {
    echo "API Server Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Get API latency
  local latency_json
  latency_json=$(get_cluster_metrics "${cluster_name}" "api_server_duration_seconds")
  
  local avg_latency max_latency
  avg_latency=$(echo "${latency_json}" | calculate_avg)
  max_latency=$(echo "${latency_json}" | calculate_max)
  
  # Convert to milliseconds
  avg_latency_ms=$(echo "${avg_latency} * 1000" | bc -l 2>/dev/null || echo "0")
  max_latency_ms=$(echo "${max_latency} * 1000" | bc -l 2>/dev/null || echo "0")
  
  {
    echo "  API Latency:"
    echo "    Average: ${avg_latency_ms}ms"
    echo "    Maximum: ${max_latency_ms}ms"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_latency_ms} > ${API_LATENCY_WARN_MS}" | bc -l 2>/dev/null || echo "0") )); then
    ((HIGH_API_LATENCY++))
    {
      printf "    %b⚠️  High API latency%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Cluster ${cluster_name} API latency: ${avg_latency_ms}ms"
  fi
  
  # Get API call rate
  local call_rate_json
  call_rate_json=$(get_cluster_metrics "${cluster_name}" "apiserver_request_count")
  
  local call_rate
  call_rate=$(echo "${call_rate_json}" | jq '.Datapoints | length' 2>/dev/null || echo "0")
  
  {
    echo "  API Call Rate: ${call_rate} datapoints in ${LOOKBACK_HOURS}h"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_addons() {
  local cluster_name="$1"
  
  {
    echo "Cluster Add-ons:"
  } >> "${OUTPUT_FILE}"
  
  local addons_json
  addons_json=$(list_addons "${cluster_name}")
  
  local addon_names
  addon_names=$(echo "${addons_json}" | jq -r '.addons[]' 2>/dev/null)
  
  if [[ -z "${addon_names}" ]]; then
    {
      echo "  No add-ons installed"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local addon_count
  addon_count=$(echo "${addon_names}" | wc -l)
  
  {
    echo "  Count: ${addon_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r addon_name; do
    [[ -z "${addon_name}" ]] && continue
    
    local addon_detail
    addon_detail=$(describe_addon "${cluster_name}" "${addon_name}")
    
    local addon_version addon_status
    addon_version=$(echo "${addon_detail}" | jq_safe '.addon.addonVersion')
    addon_status=$(echo "${addon_detail}" | jq_safe '.addon.addonHealth.issues[0].status // "HEALTHY"')
    
    {
      echo "  Add-on: ${addon_name}"
      echo "    Version: ${addon_version}"
      echo "    Status: ${addon_status}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${addon_status}" != "HEALTHY" ]]; then
      ((FAILED_ADDONS++))
      {
        printf "    %b⚠️  Add-on Status: %s%b\n" "${RED}" "${addon_status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Cluster ${cluster_name} add-on ${addon_name} status: ${addon_status}"
    else
      {
        printf "    %b✓ Add-on Healthy%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${addon_names}"
}

monitor_nodegroups() {
  local cluster_name="$1"
  
  {
    echo "Node Groups:"
  } >> "${OUTPUT_FILE}"
  
  local nodegroups_json
  nodegroups_json=$(list_nodegroups "${cluster_name}")
  
  local nodegroup_names
  nodegroup_names=$(echo "${nodegroups_json}" | jq -r '.nodegroups[]' 2>/dev/null)
  
  if [[ -z "${nodegroup_names}" ]]; then
    {
      echo "  No node groups found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local nodegroup_count
  nodegroup_count=$(echo "${nodegroup_names}" | wc -l)
  
  {
    echo "  Count: ${nodegroup_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  while IFS= read -r nodegroup_name; do
    [[ -z "${nodegroup_name}" ]] && continue
    
    log_message INFO "Analyzing node group: ${nodegroup_name}"
    
    analyze_nodegroup "${cluster_name}" "${nodegroup_name}"
    
  done <<< "${nodegroup_names}"
}

analyze_nodegroup() {
  local cluster_name="$1"
  local nodegroup_name="$2"
  
  local nodegroup_detail
  nodegroup_detail=$(describe_nodegroup "${cluster_name}" "${nodegroup_name}")
  
  local nodegroup_status desired_size current_size
  nodegroup_status=$(echo "${nodegroup_detail}" | jq_safe '.nodegroup.status')
  desired_size=$(echo "${nodegroup_detail}" | jq_safe '.nodegroup.desiredSize')
  current_size=$(echo "${nodegroup_detail}" | jq_safe '.nodegroup.resources.autoScalingGroups[0].desiredCapacity // 0')
  
  TOTAL_NODES=$((TOTAL_NODES + current_size))
  
  {
    echo "  Node Group: ${nodegroup_name}"
    echo "    Status: ${nodegroup_status}"
    echo "    Desired Nodes: ${desired_size}"
    echo "    Current Nodes: ${current_size}"
  } >> "${OUTPUT_FILE}"
  
  if [[ "${nodegroup_status}" != "ACTIVE" ]]; then
    ((UNHEALTHY_NODES++))
    {
      printf "    %b⚠️  Node Group Status: %s%b\n" "${YELLOW}" "${nodegroup_status}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Node group ${nodegroup_name} status: ${nodegroup_status}"
  else
    {
      printf "    %b✓ Node Group Active%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  # Check node health
  local health_issues
  health_issues=$(echo "${nodegroup_detail}" | jq '.nodegroup.health.issues[]?' 2>/dev/null)
  
  if [[ -n "${health_issues}" ]]; then
    {
      echo "    Health Issues:"
    } >> "${OUTPUT_FILE}"
    
    while IFS= read -r issue; do
      [[ -z "${issue}" ]] && continue
      
      local issue_code issue_message
      issue_code=$(echo "${issue}" | jq_safe '.code')
      issue_message=$(echo "${issue}" | jq_safe '.message')
      
      {
        echo "      - ${issue_code}: ${issue_message}"
      } >> "${OUTPUT_FILE}"
      
      ((UNHEALTHY_NODES++))
    done <<< "${health_issues}"
  fi
  
  # Scaling configuration
  local min_size max_size
  min_size=$(echo "${nodegroup_detail}" | jq_safe '.nodegroup.scalingConfig.minSize')
  max_size=$(echo "${nodegroup_detail}" | jq_safe '.nodegroup.scalingConfig.maxSize')
  
  {
    echo "    Scaling: min=${min_size}, max=${max_size}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_logging() {
  local cluster_detail="$1"
  local cluster_name="$2"
  
  {
    echo "Cluster Logging:"
  } >> "${OUTPUT_FILE}"
  
  local log_types=("api" "audit" "authenticator" "controllerManager" "scheduler")
  local enabled_count=0
  
  for log_type in "${log_types[@]}"; do
    local is_enabled
    is_enabled=$(echo "${cluster_detail}" | jq --arg lt "${log_type}" '.cluster.logging.clusterLogging[] | select(.types[]? == $lt) | .enabled' 2>/dev/null | head -1)
    
    if [[ "${is_enabled}" == "true" ]]; then
      ((enabled_count++))
      {
        echo "  - ${log_type}: Enabled"
      } >> "${OUTPUT_FILE}"
    else
      {
        echo "  - ${log_type}: Disabled"
      } >> "${OUTPUT_FILE}"
    fi
  done
  
  if [[ ${enabled_count} -lt 3 ]]; then
    {
      printf "  %b⚠️  Insufficient logging enabled%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Cluster ${cluster_name} has limited logging (${enabled_count}/5 types)"
  else
    {
      printf "  %b✓ Logging enabled%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

generate_summary() {
  {
    echo ""
    echo "=== EKS CLUSTER SUMMARY ==="
    echo ""
    printf "Total Clusters: %d\n" "${TOTAL_CLUSTERS}"
    printf "Total Nodes: %d\n" "${TOTAL_NODES}"
    printf "Unhealthy Nodes: %d\n" "${UNHEALTHY_NODES}"
    printf "Failed Add-ons: %d\n" "${FAILED_ADDONS}"
    printf "High API Latency: %d\n" "${HIGH_API_LATENCY}"
    echo ""
    
    if [[ ${UNHEALTHY_NODES} -gt ${NODE_NOT_READY_WARN} ]] || [[ ${FAILED_ADDONS} -gt 0 ]]; then
      printf "%b[CRITICAL] EKS cluster health issues detected%b\n" "${RED}" "${NC}"
    elif [[ ${HIGH_API_LATENCY} -gt 0 ]]; then
      printf "%b[WARNING] Performance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] All EKS clusters operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${UNHEALTHY_NODES} -gt 0 ]]; then
      echo "Node Health Recovery:"
      echo "  • Check node status with kubectl get nodes"
      echo "  • Review node system logs in CloudWatch"
      echo "  • Verify instance IAM role permissions"
      echo "  • Check security group rules for node connectivity"
      echo "  • Restart unhealthy nodes (drain then terminate)"
      echo "  • Verify node disk space and memory"
      echo "  • Review kubelet logs on problematic nodes"
      echo "  • Check node group scaling configuration"
      echo ""
    fi
    
    if [[ ${FAILED_ADDONS} -gt 0 ]]; then
      echo "Add-on Remediation:"
      echo "  • Update add-on to compatible version"
      echo "  • Check add-on IAM role permissions"
      echo "  • Verify service account exists in kube-system"
      echo "  • Review add-on CloudWatch logs"
      echo "  • Disable and re-enable add-on if stuck"
      echo "  • Check resource quotas (CPU/memory)"
      echo "  • Ensure add-on version matches cluster version"
      echo ""
    fi
    
    if [[ ${HIGH_API_LATENCY} -gt 0 ]]; then
      echo "API Performance Optimization:"
      echo "  • Review API server CPU/memory allocation"
      echo "  • Implement API request filtering"
      echo "  • Use field selectors to reduce object size"
      echo "  • Implement caching for frequent queries"
      echo "  • Review large API objects in etcd"
      echo "  • Enable API server audit for visibility"
      echo "  • Consider increasing node count in control plane"
      echo "  • Optimize client-side connection pooling"
      echo ""
    fi
    
    echo "Best Practices:"
    echo "  • Keep Kubernetes version up-to-date"
    echo "  • Use managed add-ons (not self-managed)"
    echo "  • Implement resource quotas per namespace"
    echo "  • Enable Pod Disruption Budgets"
    echo "  • Use network policies for security"
    echo "  • Implement RBAC with least privilege"
    echo "  • Use managed node groups for easier scaling"
    echo "  • Enable cluster auto-scaling (CA/HPA/VPA)"
    echo ""
    
    echo "Monitoring & Observability:"
    echo "  • Enable CloudWatch Container Insights"
    echo "  • Monitor control plane metrics"
    echo "  • Set up CloudWatch alarms for node health"
    echo "  • Track API server latency and error rate"
    echo "  • Monitor etcd database performance"
    echo "  • Use Prometheus/Grafana for detailed metrics"
    echo "  • Implement distributed tracing (Jaeger/Zipkin)"
    echo "  • Monitor node disk pressure/memory pressure"
    echo ""
    
    echo "Security Hardening:"
    echo "  • Enable audit logging for compliance"
    echo "  • Use AWS security groups properly"
    echo "  • Implement network policies (Calico/Cilium)"
    echo "  • Use Pod Security Policies/Standards"
    echo "  • Enable IMDSv2 on node instances"
    echo "  • Use IAM roles for service accounts (IRSA)"
    echo "  • Implement image scanning in ECR"
    echo "  • Enable encryption at rest for secrets"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • Use Fargate for burst/variable workloads"
    echo "  • Use Spot Instances for non-critical workloads"
    echo "  • Right-size node instance types"
    echo "  • Implement Karpenter for intelligent scaling"
    echo "  • Remove unused resources regularly"
    echo "  • Use reserved instances for predictable load"
    echo "  • Monitor unused nodes/capacity"
    echo ""
    
    echo "High Availability:"
    echo "  • Deploy clusters across multiple AZs"
    echo "  • Use node affinity for critical workloads"
    echo "  • Implement PodDisruptionBudgets"
    echo "  • Use multiple replicas for deployments"
    echo "  • Enable cluster auto-scaling"
    echo "  • Use readiness/liveness probes"
    echo "  • Implement graceful shutdown handling"
    echo "  • Test disaster recovery procedures"
    echo ""
    
    echo "Integration Points:"
    echo "  • Integrate with AWS Load Balancer Controller"
    echo "  • Use AWS IAM for authentication"
    echo "  • CloudWatch for logging and monitoring"
    echo "  • ECR for container image repository"
    echo "  • Secrets Manager for secret management"
    echo "  • X-Ray for distributed tracing"
    echo "  • VPC for networking"
    echo "  • EBS for persistent volumes"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== EKS Cluster Monitor Started ==="
  
  write_header
  monitor_clusters
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS EKS Documentation:"
    echo "  https://docs.aws.amazon.com/eks/"
    echo ""
    echo "Kubernetes Cluster Health Check:"
    echo "  kubectl cluster-info"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== EKS Cluster Monitor Completed ==="
  
  # Send alerts
  if [[ ${UNHEALTHY_NODES} -gt ${NODE_NOT_READY_WARN} ]] || [[ ${FAILED_ADDONS} -gt 0 ]]; then
    send_slack_alert "🚨 EKS cluster issues: ${UNHEALTHY_NODES} unhealthy nodes, ${FAILED_ADDONS} failed add-ons" "CRITICAL"
    send_email_alert "EKS Cluster Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${HIGH_API_LATENCY} -gt 0 ]]; then
    send_slack_alert "⚠️ EKS API latency issues detected (${HIGH_API_LATENCY} cluster(s))" "WARNING"
  fi
}

main "$@"

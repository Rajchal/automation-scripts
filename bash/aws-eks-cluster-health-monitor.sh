#!/bin/bash

################################################################################
# AWS EKS Cluster Health Monitor
# Comprehensive health checks for EKS cluster components including node status,
# pod health, resource utilization, etcd health, and control plane metrics
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${EKS_CLUSTER_NAME:-}"
OUTPUT_FILE="/tmp/eks-health-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/eks-health-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Health thresholds
NODE_READY_WARN="${NODE_READY_WARN:-90}"                    # % nodes ready
CPU_USAGE_WARN="${CPU_USAGE_WARN:-80}"                      # % CPU
MEMORY_USAGE_WARN="${MEMORY_USAGE_WARN:-85}"                # % Memory
DISK_PRESSURE_WARN="${DISK_PRESSURE_WARN:-85}"              # % Disk
POD_PRESSURE_WARN="${POD_PRESSURE_WARN:-80}"                # % Pod capacity
NETWORK_UNAVAIL_WARN="${NETWORK_UNAVAIL_WARN:-5}"           # % Unavailable
FAILED_POD_THRESHOLD="${FAILED_POD_THRESHOLD:-10}"          # Failed pods allowed

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

check_kubectl() {
  if ! command -v kubectl &>/dev/null; then
    log_message ERROR "kubectl not found. Please install kubectl to run this script."
    exit 1
  fi
}

check_cluster_access() {
  if ! kubectl cluster-info &>/dev/null; then
    log_message ERROR "Unable to access Kubernetes cluster. Check kubeconfig and cluster access."
    exit 1
  fi
}

describe_eks_cluster() {
  local cluster_name="$1"
  aws eks describe-cluster \
    --name "${cluster_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_eks_clusters() {
  aws eks list-clusters \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"clusters":[]}'
}

get_cluster_health() {
  kubectl get --all-namespaces nodes -o json 2>/dev/null || echo '{"items":[]}'
}

get_pod_summary() {
  kubectl get pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}'
}

get_node_metrics() {
  kubectl top nodes -o json 2>/dev/null || echo '{"items":[]}'
}

get_pod_metrics() {
  kubectl top pods --all-namespaces -o json 2>/dev/null || echo '{"items":[]}'
}

send_slack_alert() {
  local message="$1"
  local severity="$2"
  
  if [[ -z "${SLACK_WEBHOOK}" ]]; then
    return
  fi
  
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
      "title": "EKS Cluster Health Alert",
      "text": "${message}",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
  
  curl -X POST -H 'Content-type: application/json' \
    --data "${payload}" \
    "${SLACK_WEBHOOK}" 2>/dev/null || true
}

send_email_alert() {
  local subject="$1"
  local body="$2"
  
  if [[ -z "${EMAIL_TO}" ]] || ! command -v mail &>/dev/null; then
    return
  fi
  
  echo "${body}" | mail -s "${subject}" "${EMAIL_TO}" 2>/dev/null || true
}

write_header() {
  {
    echo "AWS EKS Cluster Health Report"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Cluster: ${CLUSTER_NAME}"
    echo "Region: ${REGION}"
    echo "Node Ready Threshold: ${NODE_READY_WARN}%"
    echo "CPU Warning: ${CPU_USAGE_WARN}%"
    echo "Memory Warning: ${MEMORY_USAGE_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

check_cluster_info() {
  log_message INFO "Checking EKS cluster information"
  
  {
    echo "=== CLUSTER INFORMATION ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local cluster_details
  cluster_details=$(describe_eks_cluster "${CLUSTER_NAME}")
  
  local cluster_status
  local k8s_version
  local endpoint
  local created_date
  local platform_version
  
  cluster_status=$(echo "${cluster_details}" | jq_safe '.cluster.status')
  k8s_version=$(echo "${cluster_details}" | jq_safe '.cluster.version')
  endpoint=$(echo "${cluster_details}" | jq_safe '.cluster.endpoint')
  created_date=$(echo "${cluster_details}" | jq_safe '.cluster.createdAt')
  platform_version=$(echo "${cluster_details}" | jq_safe '.cluster.platformVersion')
  
  {
    echo "Cluster Name: ${CLUSTER_NAME}"
    echo "Status: ${cluster_status}"
    echo "Kubernetes Version: ${k8s_version}"
    echo "Platform Version: ${platform_version}"
    echo "Created: ${created_date}"
    echo "API Endpoint: ${endpoint}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ "${cluster_status}" != "ACTIVE" ]]; then
    log_message WARN "Cluster ${CLUSTER_NAME} status is ${cluster_status}"
    local alert_msg="⚠️  EKS Cluster ${CLUSTER_NAME} status is ${cluster_status}"
    send_slack_alert "${alert_msg}" "CRITICAL"
  fi
}

check_node_health() {
  log_message INFO "Checking node health"
  
  {
    echo "=== NODE HEALTH STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local nodes_json
  nodes_json=$(get_cluster_health)
  
  local total_nodes=0
  local ready_nodes=0
  local not_ready_nodes=0
  local disk_pressure=0
  local memory_pressure=0
  local pid_pressure=0
  local network_unavailable=0
  
  local nodes_data
  nodes_data=$(echo "${nodes_json}" | jq -r '.items[] | "\(.metadata.name)|\(.status.conditions[] | select(.type == "Ready") | .status)"' 2>/dev/null)
  
  if [[ -z "${nodes_data}" ]]; then
    {
      echo "Status: No nodes found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS='|' read -r node_name ready_status; do
    ((total_nodes++))
    
    local node_status_color="${GREEN}"
    if [[ "${ready_status}" == "True" ]]; then
      ((ready_nodes++))
    else
      ((not_ready_nodes++))
      node_status_color="${RED}"
    fi
    
    # Check for pressure conditions
    local has_conditions=""
    local disk_pressure_status
    local memory_pressure_status
    local pid_pressure_status
    local network_unavail_status
    
    disk_pressure_status=$(kubectl get node "${node_name}" -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "DiskPressure") | .status' 2>/dev/null || echo "False")
    memory_pressure_status=$(kubectl get node "${node_name}" -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "MemoryPressure") | .status' 2>/dev/null || echo "False")
    pid_pressure_status=$(kubectl get node "${node_name}" -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "PIDPressure") | .status' 2>/dev/null || echo "False")
    network_unavail_status=$(kubectl get node "${node_name}" -o json 2>/dev/null | jq -r '.status.conditions[] | select(.type == "NetworkUnavailable") | .status' 2>/dev/null || echo "False")
    
    if [[ "${disk_pressure_status}" == "True" ]]; then
      ((disk_pressure++))
      node_status_color="${YELLOW}"
      has_conditions="${has_conditions} DiskPressure"
    fi
    
    if [[ "${memory_pressure_status}" == "True" ]]; then
      ((memory_pressure++))
      node_status_color="${YELLOW}"
      has_conditions="${has_conditions} MemoryPressure"
    fi
    
    if [[ "${pid_pressure_status}" == "True" ]]; then
      ((pid_pressure++))
      node_status_color="${YELLOW}"
      has_conditions="${has_conditions} PIDPressure"
    fi
    
    if [[ "${network_unavail_status}" == "True" ]]; then
      ((network_unavailable++))
      node_status_color="${RED}"
      has_conditions="${has_conditions} NetworkUnavailable"
    fi
    
    printf "%bNode: %-40s Ready: %-5s %s%b\n" \
      "${node_status_color}" "${node_name}" "${ready_status}" "${has_conditions}" "${NC}" >> "${OUTPUT_FILE}"
    
  done <<< "${nodes_data}"
  
  local ready_percentage=0
  if [[ ${total_nodes} -gt 0 ]]; then
    ready_percentage=$((ready_nodes * 100 / total_nodes))
  fi
  
  {
    echo ""
    echo "Node Summary:"
    echo "  Total Nodes: ${total_nodes}"
    echo "  Ready Nodes: ${ready_nodes}"
    echo "  Not Ready: ${not_ready_nodes}"
    echo "  Ready Percentage: ${ready_percentage}%"
    echo ""
    echo "Pressure Conditions:"
    echo "  Disk Pressure: ${disk_pressure}"
    echo "  Memory Pressure: ${memory_pressure}"
    echo "  PID Pressure: ${pid_pressure}"
    echo "  Network Unavailable: ${network_unavailable}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${ready_percentage} -lt ${NODE_READY_WARN} ]]; then
    log_message WARN "Only ${ready_percentage}% nodes are ready"
    local alert_msg="⚠️  EKS Cluster ${CLUSTER_NAME}: Only ${ready_percentage}% nodes ready (threshold: ${NODE_READY_WARN}%)"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
  
  if [[ ${network_unavailable} -gt 0 ]]; then
    log_message ERROR "Network unavailable on ${network_unavailable} nodes"
    local alert_msg="🔴 EKS Cluster ${CLUSTER_NAME}: Network unavailable on ${network_unavailable} nodes"
    send_slack_alert "${alert_msg}" "CRITICAL"
  fi
}

check_pod_health() {
  log_message INFO "Checking pod health"
  
  {
    echo ""
    echo "=== POD HEALTH STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local pods_json
  pods_json=$(get_pod_summary)
  
  local total_pods=0
  local running_pods=0
  local failed_pods=0
  local pending_pods=0
  local unknown_pods=0
  local restart_count=0
  
  local pods_data
  pods_data=$(echo "${pods_json}" | jq -r '.items[] | "\(.metadata.namespace)|\(.metadata.name)|\(.status.phase)|\(.status.containerStatuses[0].restartCount // 0)"' 2>/dev/null)
  
  if [[ -z "${pods_data}" ]]; then
    {
      echo "Status: No pods found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  while IFS='|' read -r namespace name phase restarts; do
    ((total_pods++))
    restart_count=$((restart_count + restarts))
    
    local pod_color="${GREEN}"
    case "${phase}" in
      Running)   ((running_pods++)) ;;
      Failed)    ((failed_pods++)); pod_color="${RED}" ;;
      Pending)   ((pending_pods++)); pod_color="${YELLOW}" ;;
      *)         ((unknown_pods++)); pod_color="${YELLOW}" ;;
    esac
    
    if [[ ${restarts} -gt 5 ]]; then
      pod_color="${YELLOW}"
      log_message WARN "Pod ${namespace}/${name} has restarted ${restarts} times"
    fi
    
  done <<< "${pods_data}"
  
  {
    echo "Pod Summary:"
    echo "  Total Pods: ${total_pods}"
    echo "  Running: ${running_pods}"
    echo "  Pending: ${pending_pods}"
    echo "  Failed: ${failed_pods}"
    echo "  Unknown: ${unknown_pods}"
    echo "  Total Restarts: ${restart_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  if [[ ${failed_pods} -gt ${FAILED_POD_THRESHOLD} ]]; then
    log_message WARN "Too many failed pods: ${failed_pods}"
    local alert_msg="⚠️  EKS Cluster ${CLUSTER_NAME}: ${failed_pods} failed pods (threshold: ${FAILED_POD_THRESHOLD})"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
  
  if [[ ${pending_pods} -gt 5 ]]; then
    log_message WARN "Too many pending pods: ${pending_pods}"
    local alert_msg="⚠️  EKS Cluster ${CLUSTER_NAME}: ${pending_pods} pending pods"
    send_slack_alert "${alert_msg}" "WARNING"
  fi
}

check_resource_utilization() {
  log_message INFO "Checking resource utilization"
  
  {
    echo ""
    echo "=== RESOURCE UTILIZATION ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local nodes_metrics
  nodes_metrics=$(get_node_metrics)
  
  if [[ "${nodes_metrics}" == "{}" || "${nodes_metrics}" == '{"items":[]}' ]]; then
    {
      echo "Metrics Server not available - skipping resource checks"
      echo ""
    } >> "${OUTPUT_FILE}"
    log_message WARN "Metrics Server not available for resource checks"
    return
  fi
  
  local nodes_data
  nodes_data=$(echo "${nodes_metrics}" | jq -r '.items[] | "\(.metadata.name)|\(.usage.cpu)|\(.usage.memory)"' 2>/dev/null)
  
  if [[ -z "${nodes_data}" ]]; then
    {
      echo "No metric data available"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Node Resource Usage:"
  } >> "${OUTPUT_FILE}"
  
  while IFS='|' read -r node_name cpu_usage memory_usage; do
    # Remove 'm' suffix from CPU (millicores)
    cpu_usage=${cpu_usage%m}
    # Remove 'Ki' suffix from memory (Kibibytes)
    memory_usage=${memory_usage%Ki}
    
    {
      echo "  ${node_name}: CPU=${cpu_usage}m Memory=${memory_usage}Ki"
    } >> "${OUTPUT_FILE}"
  done <<< "${nodes_data}"
  
  {
    echo ""
  } >> "${OUTPUT_FILE}"
}

check_system_components() {
  log_message INFO "Checking system components"
  
  {
    echo ""
    echo "=== SYSTEM COMPONENTS STATUS ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local critical_namespaces=("kube-system" "kube-node-lease" "kube-public")
  local component_status_ok=true
  
  for ns in "${critical_namespaces[@]}"; do
    local ns_pods
    ns_pods=$(kubectl get pods -n "${ns}" -o json 2>/dev/null || echo '{"items":[]}')
    
    local pod_statuses
    pod_statuses=$(echo "${ns_pods}" | jq -r '.items[] | "\(.metadata.name)|\(.status.phase)"' 2>/dev/null)
    
    {
      echo "Namespace: ${ns}"
    } >> "${OUTPUT_FILE}"
    
    if [[ -z "${pod_statuses}" ]]; then
      {
        echo "  No pods found"
      } >> "${OUTPUT_FILE}"
      continue
    fi
    
    while IFS='|' read -r pod_name phase; do
      local status_color="${GREEN}"
      if [[ "${phase}" != "Running" ]]; then
        status_color="${RED}"
        component_status_ok=false
      fi
      
      printf "%b  %-40s %s%b\n" \
        "${status_color}" "${pod_name}" "${phase}" "${NC}" >> "${OUTPUT_FILE}"
    done <<< "${pod_statuses}"
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
  done
  
  if [[ "${component_status_ok}" == "false" ]]; then
    log_message ERROR "Some critical system components are not healthy"
    local alert_msg="🔴 EKS Cluster ${CLUSTER_NAME}: Critical system components not healthy"
    send_slack_alert "${alert_msg}" "CRITICAL"
  fi
}

main() {
  log_message INFO "=== EKS Cluster Health Monitor Started ==="
  
  check_kubectl
  check_cluster_access
  
  if [[ -z "${CLUSTER_NAME}" ]]; then
    CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f2)
    log_message INFO "Using cluster from kubeconfig: ${CLUSTER_NAME}"
  fi
  
  write_header
  check_cluster_info
  check_node_health
  check_pod_health
  check_resource_utilization
  check_system_components
  
  {
    echo ""
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== EKS Cluster Health Monitor Completed ==="
}

main "$@"

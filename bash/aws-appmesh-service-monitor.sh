#!/bin/bash

################################################################################
# AWS App Mesh Service Mesh Monitor
# Monitors App Mesh virtual services, nodes, routers, routes, gateways, and
# provides insights on latency, retry configurations, TLS compliance, and
# Envoy proxy health.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/appmesh-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/appmesh-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"

# Thresholds
LATENCY_WARN_MS="${LATENCY_WARN_MS:-500}"           # milliseconds
RETRY_THRESHOLD="${RETRY_THRESHOLD:-10}"            # % of requests retried
ERROR_RATE_WARN="${ERROR_RATE_WARN:-5}"            # % error rate
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_MESHES=0
TOTAL_SERVICES=0
TOTAL_NODES=0
TOTAL_GATEWAYS=0
HIGH_LATENCY_SERVICES=0
TLS_NON_COMPLIANT=0
HIGH_ERROR_RATE=0
UNHEALTHY_NODES=0

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
      "title": "App Mesh Alert",
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
    echo "AWS App Mesh Service Monitor"
    echo "============================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Analysis Window: ${LOOKBACK_HOURS}h"
    echo ""
    echo "Thresholds:"
    echo "  Latency Warning: ${LATENCY_WARN_MS}ms"
    echo "  Retry Threshold: ${RETRY_THRESHOLD}%"
    echo "  Error Rate Warning: ${ERROR_RATE_WARN}%"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_meshes() {
  aws appmesh list-meshes \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"meshes":[]}'
}

describe_mesh() {
  local mesh_name="$1"
  aws appmesh describe-mesh \
    --mesh-name "${mesh_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_virtual_services() {
  local mesh_name="$1"
  aws appmesh list-virtual-services \
    --mesh-name "${mesh_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"virtualServices":[]}'
}

describe_virtual_service() {
  local mesh_name="$1"
  local service_name="$2"
  aws appmesh describe-virtual-service \
    --mesh-name "${mesh_name}" \
    --virtual-service-name "${service_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_virtual_nodes() {
  local mesh_name="$1"
  aws appmesh list-virtual-nodes \
    --mesh-name "${mesh_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"virtualNodes":[]}'
}

describe_virtual_node() {
  local mesh_name="$1"
  local node_name="$2"
  aws appmesh describe-virtual-node \
    --mesh-name "${mesh_name}" \
    --virtual-node-name "${node_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_virtual_routers() {
  local mesh_name="$1"
  aws appmesh list-virtual-routers \
    --mesh-name "${mesh_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"virtualRouters":[]}'
}

describe_virtual_router() {
  local mesh_name="$1"
  local router_name="$2"
  aws appmesh describe-virtual-router \
    --mesh-name "${mesh_name}" \
    --virtual-router-name "${router_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_routes() {
  local mesh_name="$1"
  local router_name="$2"
  aws appmesh list-routes \
    --mesh-name "${mesh_name}" \
    --virtual-router-name "${router_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"routes":[]}'
}

describe_route() {
  local mesh_name="$1"
  local router_name="$2"
  local route_name="$3"
  aws appmesh describe-route \
    --mesh-name "${mesh_name}" \
    --virtual-router-name "${router_name}" \
    --route-name "${route_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

list_virtual_gateways() {
  local mesh_name="$1"
  aws appmesh list-virtual-gateways \
    --mesh-name "${mesh_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"virtualGateways":[]}'
}

describe_virtual_gateway() {
  local mesh_name="$1"
  local gateway_name="$2"
  aws appmesh describe-virtual-gateway \
    --mesh-name "${mesh_name}" \
    --virtual-gateway-name "${gateway_name}" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{}'
}

get_envoy_metrics() {
  local mesh_name="$1"
  local virtual_node="$2"
  local metric_name="$3"
  local start_time end_time
  
  start_time=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)
  end_time=$(date -u +%Y-%m-%dT%H:%M:%S)
  
  aws cloudwatch get-metric-statistics \
    --namespace AWS/AppMesh \
    --metric-name "${metric_name}" \
    --dimensions Name=Mesh,Value="${mesh_name}" Name=VirtualNode,Value="${virtual_node}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period "${METRIC_PERIOD}" \
    --statistics Average,Sum,Maximum \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_avg() {
  jq -r '.Datapoints[].Average' 2>/dev/null | \
    awk '{s+=$1; c++} END {if (c>0) printf "%.2f", s/c; else print "0"}'
}

calculate_sum() {
  jq -r '.Datapoints[].Sum' 2>/dev/null | \
    awk '{s+=$1} END {printf "%.0f", s}'
}

calculate_max() {
  jq -r '.Datapoints[].Maximum' 2>/dev/null | \
    awk 'BEGIN {max=0} {if ($1>max) max=$1} END {printf "%.2f", max}'
}

monitor_meshes() {
  log_message INFO "Starting App Mesh monitoring"
  
  {
    echo "=== APP MESH INVENTORY ==="
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local meshes_json
  meshes_json=$(list_meshes)
  
  local mesh_count
  mesh_count=$(echo "${meshes_json}" | jq '.meshes | length' 2>/dev/null || echo "0")
  
  TOTAL_MESHES=${mesh_count}
  
  if [[ ${mesh_count} -eq 0 ]]; then
    {
      echo "No App Meshes found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "Total Meshes: ${mesh_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local meshes
  meshes=$(echo "${meshes_json}" | jq -r '.meshes[].meshName' 2>/dev/null)
  
  while IFS= read -r mesh_name; do
    [[ -z "${mesh_name}" ]] && continue
    
    log_message INFO "Analyzing mesh: ${mesh_name}"
    
    local mesh_detail
    mesh_detail=$(describe_mesh "${mesh_name}")
    
    local status egress_filter
    status=$(echo "${mesh_detail}" | jq_safe '.mesh.status.status')
    egress_filter=$(echo "${mesh_detail}" | jq_safe '.mesh.spec.egressFilter.type')
    
    {
      echo "=== MESH: ${mesh_name} ==="
      echo ""
      echo "Status: ${status}"
      echo "Egress Filter: ${egress_filter}"
      echo ""
    } >> "${OUTPUT_FILE}"
    
    # Monitor components
    monitor_virtual_services "${mesh_name}"
    monitor_virtual_nodes "${mesh_name}"
    monitor_virtual_routers "${mesh_name}"
    monitor_virtual_gateways "${mesh_name}"
    
    {
      echo "---"
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${meshes}"
}

monitor_virtual_services() {
  local mesh_name="$1"
  
  {
    echo "Virtual Services:"
  } >> "${OUTPUT_FILE}"
  
  local services_json
  services_json=$(list_virtual_services "${mesh_name}")
  
  local service_count
  service_count=$(echo "${services_json}" | jq '.virtualServices | length' 2>/dev/null || echo "0")
  
  TOTAL_SERVICES=$((TOTAL_SERVICES + service_count))
  
  if [[ ${service_count} -eq 0 ]]; then
    {
      echo "  No virtual services found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Count: ${service_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local services
  services=$(echo "${services_json}" | jq -r '.virtualServices[].virtualServiceName' 2>/dev/null)
  
  while IFS= read -r service_name; do
    [[ -z "${service_name}" ]] && continue
    
    local service_detail
    service_detail=$(describe_virtual_service "${mesh_name}" "${service_name}")
    
    local status provider_type provider_name
    status=$(echo "${service_detail}" | jq_safe '.virtualService.status.status')
    provider_type=$(echo "${service_detail}" | jq_safe '.virtualService.spec.provider | keys[0]')
    provider_name=$(echo "${service_detail}" | jq_safe ".virtualService.spec.provider.${provider_type}.${provider_type}Name")
    
    {
      echo "  Service: ${service_name}"
      echo "    Status: ${status}"
      echo "    Provider Type: ${provider_type}"
      echo "    Provider Name: ${provider_name}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${status}" == "ACTIVE" ]]; then
      {
        printf "    %b✓ Service Active%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "    %b⚠️  Service Status: %s%b\n" "${YELLOW}" "${status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Virtual service ${service_name} status: ${status}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${services}"
}

monitor_virtual_nodes() {
  local mesh_name="$1"
  
  {
    echo "Virtual Nodes:"
  } >> "${OUTPUT_FILE}"
  
  local nodes_json
  nodes_json=$(list_virtual_nodes "${mesh_name}")
  
  local node_count
  node_count=$(echo "${nodes_json}" | jq '.virtualNodes | length' 2>/dev/null || echo "0")
  
  TOTAL_NODES=$((TOTAL_NODES + node_count))
  
  if [[ ${node_count} -eq 0 ]]; then
    {
      echo "  No virtual nodes found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Count: ${node_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local nodes
  nodes=$(echo "${nodes_json}" | jq -r '.virtualNodes[].virtualNodeName' 2>/dev/null)
  
  while IFS= read -r node_name; do
    [[ -z "${node_name}" ]] && continue
    
    log_message INFO "Analyzing virtual node: ${node_name}"
    
    local node_detail
    node_detail=$(describe_virtual_node "${mesh_name}" "${node_name}")
    
    local status
    status=$(echo "${node_detail}" | jq_safe '.virtualNode.status.status')
    
    {
      echo "  Node: ${node_name}"
      echo "    Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    # Check TLS configuration
    check_tls_config "${node_detail}" "${node_name}"
    
    # Check backend defaults
    check_backend_defaults "${node_detail}"
    
    # Get Envoy metrics
    analyze_node_metrics "${mesh_name}" "${node_name}"
    
    if [[ "${status}" == "ACTIVE" ]]; then
      {
        printf "    %b✓ Node Active%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      ((UNHEALTHY_NODES++))
      {
        printf "    %b⚠️  Node Status: %s%b\n" "${YELLOW}" "${status}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Virtual node ${node_name} status: ${status}"
    fi
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${nodes}"
}

check_tls_config() {
  local node_detail="$1"
  local node_name="$2"
  
  local tls_mode
  tls_mode=$(echo "${node_detail}" | jq_safe '.virtualNode.spec.listeners[0].tls.mode')
  
  {
    echo "    TLS Configuration:"
  } >> "${OUTPUT_FILE}"
  
  if [[ -z "${tls_mode}" || "${tls_mode}" == "null" ]]; then
    ((TLS_NON_COMPLIANT++))
    {
      printf "      %b⚠️  TLS not configured%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Node ${node_name} does not have TLS configured"
  else
    {
      echo "      Mode: ${tls_mode}"
      printf "      %b✓ TLS enabled%b\n" "${GREEN}" "${NC}"
    } >> "${OUTPUT_FILE}"
  fi
}

check_backend_defaults() {
  local node_detail="$1"
  
  local client_policy
  client_policy=$(echo "${node_detail}" | jq '.virtualNode.spec.backendDefaults.clientPolicy' 2>/dev/null)
  
  if [[ -z "${client_policy}" || "${client_policy}" == "null" ]]; then
    {
      echo "    Backend Defaults: None configured"
    } >> "${OUTPUT_FILE}"
  else
    local tls_enforce
    tls_enforce=$(echo "${node_detail}" | jq_safe '.virtualNode.spec.backendDefaults.clientPolicy.tls.enforce')
    
    {
      echo "    Backend TLS Enforcement: ${tls_enforce}"
    } >> "${OUTPUT_FILE}"
  fi
}

analyze_node_metrics() {
  local mesh_name="$1"
  local node_name="$2"
  
  {
    echo "    Metrics (${LOOKBACK_HOURS}h):"
  } >> "${OUTPUT_FILE}"
  
  # Request count
  local request_json
  request_json=$(get_envoy_metrics "${mesh_name}" "${node_name}" "RequestCount")
  local request_count
  request_count=$(echo "${request_json}" | calculate_sum)
  
  {
    echo "      Total Requests: ${request_count}"
  } >> "${OUTPUT_FILE}"
  
  if [[ ${request_count} -eq 0 ]]; then
    {
      echo "      No traffic data available"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  # Target response time (latency)
  local latency_json
  latency_json=$(get_envoy_metrics "${mesh_name}" "${node_name}" "TargetResponseTime")
  local avg_latency max_latency
  avg_latency=$(echo "${latency_json}" | calculate_avg)
  max_latency=$(echo "${latency_json}" | calculate_max)
  
  {
    echo "      Avg Latency: ${avg_latency}ms"
    echo "      Max Latency: ${max_latency}ms"
  } >> "${OUTPUT_FILE}"
  
  if (( $(echo "${avg_latency} > ${LATENCY_WARN_MS}" | bc -l 2>/dev/null || echo "0") )); then
    ((HIGH_LATENCY_SERVICES++))
    {
      printf "      %b⚠️  High latency detected%b\n" "${YELLOW}" "${NC}"
    } >> "${OUTPUT_FILE}"
    log_message WARN "Node ${node_name} avg latency: ${avg_latency}ms"
  fi
  
  # HTTP status codes
  local http_5xx_json http_4xx_json
  http_5xx_json=$(get_envoy_metrics "${mesh_name}" "${node_name}" "HTTPCode_Target_5XX_Count")
  http_4xx_json=$(get_envoy_metrics "${mesh_name}" "${node_name}" "HTTPCode_Target_4XX_Count")
  
  local count_5xx count_4xx
  count_5xx=$(echo "${http_5xx_json}" | calculate_sum)
  count_4xx=$(echo "${http_4xx_json}" | calculate_sum)
  
  {
    echo "      4XX Responses: ${count_4xx}"
    echo "      5XX Responses: ${count_5xx}"
  } >> "${OUTPUT_FILE}"
  
  # Calculate error rate
  if [[ ${request_count} -gt 0 ]]; then
    local error_rate
    error_rate=$(echo "scale=2; (${count_5xx} + ${count_4xx}) * 100 / ${request_count}" | bc -l 2>/dev/null || echo "0")
    
    {
      echo "      Error Rate: ${error_rate}%"
    } >> "${OUTPUT_FILE}"
    
    if (( $(echo "${error_rate} > ${ERROR_RATE_WARN}" | bc -l) )); then
      ((HIGH_ERROR_RATE++))
      {
        printf "      %b⚠️  High error rate%b\n" "${YELLOW}" "${NC}"
      } >> "${OUTPUT_FILE}"
      log_message WARN "Node ${node_name} error rate: ${error_rate}%"
    fi
  fi
  
  # Connection metrics
  local connection_error_json
  connection_error_json=$(get_envoy_metrics "${mesh_name}" "${node_name}" "ConnectionError")
  local connection_errors
  connection_errors=$(echo "${connection_error_json}" | calculate_sum)
  
  {
    echo "      Connection Errors: ${connection_errors}"
  } >> "${OUTPUT_FILE}"
}

monitor_virtual_routers() {
  local mesh_name="$1"
  
  {
    echo "Virtual Routers:"
  } >> "${OUTPUT_FILE}"
  
  local routers_json
  routers_json=$(list_virtual_routers "${mesh_name}")
  
  local router_count
  router_count=$(echo "${routers_json}" | jq '.virtualRouters | length' 2>/dev/null || echo "0")
  
  if [[ ${router_count} -eq 0 ]]; then
    {
      echo "  No virtual routers found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Count: ${router_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local routers
  routers=$(echo "${routers_json}" | jq -r '.virtualRouters[].virtualRouterName' 2>/dev/null)
  
  while IFS= read -r router_name; do
    [[ -z "${router_name}" ]] && continue
    
    local router_detail
    router_detail=$(describe_virtual_router "${mesh_name}" "${router_name}")
    
    local status
    status=$(echo "${router_detail}" | jq_safe '.virtualRouter.status.status')
    
    {
      echo "  Router: ${router_name}"
      echo "    Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    # List routes
    analyze_routes "${mesh_name}" "${router_name}"
    
    {
      echo ""
    } >> "${OUTPUT_FILE}"
    
  done <<< "${routers}"
}

analyze_routes() {
  local mesh_name="$1"
  local router_name="$2"
  
  {
    echo "    Routes:"
  } >> "${OUTPUT_FILE}"
  
  local routes_json
  routes_json=$(list_routes "${mesh_name}" "${router_name}")
  
  local route_count
  route_count=$(echo "${routes_json}" | jq '.routes | length' 2>/dev/null || echo "0")
  
  if [[ ${route_count} -eq 0 ]]; then
    {
      echo "      No routes configured"
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  local routes
  routes=$(echo "${routes_json}" | jq -r '.routes[].routeName' 2>/dev/null)
  
  while IFS= read -r route_name; do
    [[ -z "${route_name}" ]] && continue
    
    local route_detail
    route_detail=$(describe_route "${mesh_name}" "${router_name}" "${route_name}")
    
    local status priority
    status=$(echo "${route_detail}" | jq_safe '.route.status.status')
    priority=$(echo "${route_detail}" | jq_safe '.route.spec.priority // "default"')
    
    {
      echo "      Route: ${route_name}"
      echo "        Status: ${status}"
      echo "        Priority: ${priority}"
    } >> "${OUTPUT_FILE}"
    
    # Check retry policy
    check_retry_policy "${route_detail}"
    
    # Check timeout
    check_timeout_config "${route_detail}"
    
  done <<< "${routes}"
}

check_retry_policy() {
  local route_detail="$1"
  
  local retry_policy
  retry_policy=$(echo "${route_detail}" | jq '.route.spec.httpRoute.retryPolicy' 2>/dev/null)
  
  if [[ -z "${retry_policy}" || "${retry_policy}" == "null" ]]; then
    {
      echo "        Retry Policy: None"
    } >> "${OUTPUT_FILE}"
  else
    local max_retries
    max_retries=$(echo "${route_detail}" | jq_safe '.route.spec.httpRoute.retryPolicy.maxRetries')
    
    {
      echo "        Max Retries: ${max_retries}"
    } >> "${OUTPUT_FILE}"
  fi
}

check_timeout_config() {
  local route_detail="$1"
  
  local timeout
  timeout=$(echo "${route_detail}" | jq '.route.spec.httpRoute.timeout' 2>/dev/null)
  
  if [[ -z "${timeout}" || "${timeout}" == "null" ]]; then
    {
      echo "        Timeout: Default"
    } >> "${OUTPUT_FILE}"
  else
    local idle_timeout per_request_timeout
    idle_timeout=$(echo "${route_detail}" | jq_safe '.route.spec.httpRoute.timeout.idle.value')
    per_request_timeout=$(echo "${route_detail}" | jq_safe '.route.spec.httpRoute.timeout.perRequest.value')
    
    {
      echo "        Idle Timeout: ${idle_timeout}ms"
      echo "        Per-Request Timeout: ${per_request_timeout}ms"
    } >> "${OUTPUT_FILE}"
  fi
}

monitor_virtual_gateways() {
  local mesh_name="$1"
  
  {
    echo "Virtual Gateways:"
  } >> "${OUTPUT_FILE}"
  
  local gateways_json
  gateways_json=$(list_virtual_gateways "${mesh_name}")
  
  local gateway_count
  gateway_count=$(echo "${gateways_json}" | jq '.virtualGateways | length' 2>/dev/null || echo "0")
  
  TOTAL_GATEWAYS=$((TOTAL_GATEWAYS + gateway_count))
  
  if [[ ${gateway_count} -eq 0 ]]; then
    {
      echo "  No virtual gateways found"
      echo ""
    } >> "${OUTPUT_FILE}"
    return
  fi
  
  {
    echo "  Count: ${gateway_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
  
  local gateways
  gateways=$(echo "${gateways_json}" | jq -r '.virtualGateways[].virtualGatewayName' 2>/dev/null)
  
  while IFS= read -r gateway_name; do
    [[ -z "${gateway_name}" ]] && continue
    
    local gateway_detail
    gateway_detail=$(describe_virtual_gateway "${mesh_name}" "${gateway_name}")
    
    local status
    status=$(echo "${gateway_detail}" | jq_safe '.virtualGateway.status.status')
    
    {
      echo "  Gateway: ${gateway_name}"
      echo "    Status: ${status}"
    } >> "${OUTPUT_FILE}"
    
    # Check listener configuration
    local listener_count
    listener_count=$(echo "${gateway_detail}" | jq '.virtualGateway.spec.listeners | length' 2>/dev/null || echo "0")
    
    {
      echo "    Listeners: ${listener_count}"
    } >> "${OUTPUT_FILE}"
    
    if [[ "${status}" == "ACTIVE" ]]; then
      {
        printf "    %b✓ Gateway Active%b\n" "${GREEN}" "${NC}"
      } >> "${OUTPUT_FILE}"
    else
      {
        printf "    %b⚠️  Gateway Status: %s%b\n" "${YELLOW}" "${status}" "${NC}"
      } >> "${OUTPUT_FILE}"
    fi
    
  done <<< "${gateways}"
}

generate_summary() {
  {
    echo ""
    echo "=== APP MESH SUMMARY ==="
    echo ""
    printf "Total Meshes: %d\n" "${TOTAL_MESHES}"
    printf "Total Virtual Services: %d\n" "${TOTAL_SERVICES}"
    printf "Total Virtual Nodes: %d\n" "${TOTAL_NODES}"
    printf "Total Virtual Gateways: %d\n" "${TOTAL_GATEWAYS}"
    echo ""
    printf "High Latency Services: %d\n" "${HIGH_LATENCY_SERVICES}"
    printf "High Error Rate Services: %d\n" "${HIGH_ERROR_RATE}"
    printf "TLS Non-Compliant Nodes: %d\n" "${TLS_NON_COMPLIANT}"
    printf "Unhealthy Nodes: %d\n" "${UNHEALTHY_NODES}"
    echo ""
    
    if [[ ${UNHEALTHY_NODES} -gt 0 ]] || [[ ${HIGH_ERROR_RATE} -gt 0 ]]; then
      printf "%b[CRITICAL] Service mesh health issues detected%b\n" "${RED}" "${NC}"
    elif [[ ${HIGH_LATENCY_SERVICES} -gt 0 ]] || [[ ${TLS_NON_COMPLIANT} -gt 0 ]]; then
      printf "%b[WARNING] Performance or compliance issues detected%b\n" "${YELLOW}" "${NC}"
    else
      printf "%b[HEALTHY] Service mesh operating normally%b\n" "${GREEN}" "${NC}"
    fi
    
    echo ""
  } >> "${OUTPUT_FILE}"
}

recommendations() {
  {
    echo "=== RECOMMENDATIONS ==="
    echo ""
    
    if [[ ${HIGH_LATENCY_SERVICES} -gt 0 ]]; then
      echo "Latency Optimization:"
      echo "  • Review target response times in CloudWatch"
      echo "  • Check for network bottlenecks between services"
      echo "  • Optimize application code and database queries"
      echo "  • Consider implementing caching strategies"
      echo "  • Review Envoy proxy resource allocation"
      echo "  • Enable connection pooling in Envoy"
      echo "  • Adjust timeout configurations"
      echo ""
    fi
    
    if [[ ${HIGH_ERROR_RATE} -gt 0 ]]; then
      echo "Error Rate Remediation:"
      echo "  • Review application logs for root cause"
      echo "  • Check service discovery and DNS resolution"
      echo "  • Verify backend service health checks"
      echo "  • Review retry policies (exponential backoff)"
      echo "  • Implement circuit breaker patterns"
      echo "  • Monitor connection error metrics"
      echo ""
    fi
    
    if [[ ${TLS_NON_COMPLIANT} -gt 0 ]]; then
      echo "TLS Compliance:"
      echo "  • Enable TLS on all virtual node listeners"
      echo "  • Use AWS ACM for certificate management"
      echo "  • Configure mutual TLS (mTLS) for zero-trust"
      echo "  • Set TLS mode to STRICT for production"
      echo "  • Rotate certificates regularly (90 days)"
      echo "  • Enforce TLS in backend client policies"
      echo "  • Use SDS (Secret Discovery Service) for certs"
      echo ""
    fi
    
    if [[ ${UNHEALTHY_NODES} -gt 0 ]]; then
      echo "Node Health Recovery:"
      echo "  • Check ECS task or Kubernetes pod status"
      echo "  • Verify Envoy proxy sidecar is running"
      echo "  • Review IAM permissions for App Mesh"
      echo "  • Check security group configurations"
      echo "  • Verify service discovery integration"
      echo "  • Review Envoy bootstrap configuration"
      echo ""
    fi
    
    echo "Traffic Management Best Practices:"
    echo "  • Use weighted targets for canary deployments"
    echo "  • Implement retry policies with exponential backoff"
    echo "  • Configure idle and per-request timeouts"
    echo "  • Use route priorities for traffic shaping"
    echo "  • Enable access logs for debugging"
    echo "  • Implement health checks on all targets"
    echo "  • Use virtual gateways for ingress control"
    echo ""
    
    echo "Observability & Monitoring:"
    echo "  • Enable Envoy access logging to CloudWatch"
    echo "  • Use X-Ray for distributed tracing"
    echo "  • Monitor key CloudWatch metrics:"
    echo "    - TargetResponseTime (latency)"
    echo "    - RequestCount (throughput)"
    echo "    - HTTPCode_Target_5XX_Count (errors)"
    echo "    - ConnectionError (connectivity)"
    echo "  • Set up CloudWatch alarms for anomalies"
    echo "  • Use App Mesh Controller logs for troubleshooting"
    echo "  • Implement Prometheus/Grafana for Envoy metrics"
    echo ""
    
    echo "Security Hardening:"
    echo "  • Enable egress filtering (ALLOW_ALL or DROP_ALL)"
    echo "  • Use IAM policies for fine-grained access"
    echo "  • Implement network segmentation with backends"
    echo "  • Rotate TLS certificates automatically"
    echo "  • Use AWS Secrets Manager for sensitive data"
    echo "  • Enable AWS Config rules for compliance"
    echo "  • Audit mesh changes via CloudTrail"
    echo ""
    
    echo "Performance Optimization:"
    echo "  • Enable connection pooling in Envoy"
    echo "  • Tune Envoy proxy CPU/memory allocation"
    echo "  • Use gRPC for inter-service communication"
    echo "  • Implement request hedging for latency"
    echo "  • Configure outlier detection for bad instances"
    echo "  • Use DNS-based service discovery (Cloud Map)"
    echo "  • Optimize Envoy listener filters"
    echo ""
    
    echo "Cost Optimization:"
    echo "  • App Mesh is free (pay for Envoy proxy resources)"
    echo "  • Right-size Envoy sidecar containers"
    echo "  • Use AWS Fargate Spot for non-critical workloads"
    echo "  • Optimize CloudWatch Logs retention"
    echo "  • Disable verbose logging in production"
    echo "  • Clean up unused virtual nodes/services"
    echo ""
    
    echo "High Availability:"
    echo "  • Deploy services across multiple AZs"
    echo "  • Configure retry policies with circuit breakers"
    echo "  • Use virtual gateways for ingress redundancy"
    echo "  • Implement graceful shutdown for rolling updates"
    echo "  • Set reasonable connection timeouts"
    echo "  • Use health checks for automatic failover"
    echo ""
  } >> "${OUTPUT_FILE}"
}

main() {
  log_message INFO "=== App Mesh Service Monitor Started ==="
  
  write_header
  monitor_meshes
  generate_summary
  recommendations
  
  {
    echo "Report saved to: ${OUTPUT_FILE}"
    echo "Log file: ${LOG_FILE}"
    echo ""
    echo "AWS App Mesh Documentation:"
    echo "  https://docs.aws.amazon.com/app-mesh/"
  } >> "${OUTPUT_FILE}"
  
  cat "${OUTPUT_FILE}"
  
  log_message INFO "=== App Mesh Service Monitor Completed ==="
  
  # Send alerts
  if [[ ${UNHEALTHY_NODES} -gt 0 ]] || [[ ${HIGH_ERROR_RATE} -gt 0 ]]; then
    send_slack_alert "🚨 App Mesh critical issues: ${UNHEALTHY_NODES} unhealthy nodes, ${HIGH_ERROR_RATE} high error rate services" "CRITICAL"
    send_email_alert "App Mesh Critical Alert" "$(cat "${OUTPUT_FILE}")"
  elif [[ ${HIGH_LATENCY_SERVICES} -gt 0 ]]; then
    send_slack_alert "⚠️ ${HIGH_LATENCY_SERVICES} App Mesh service(s) with high latency" "WARNING"
  fi
}

main "$@"

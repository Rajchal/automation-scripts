#!/bin/bash

################################################################################
# AWS EKS Cluster Monitor
# Monitors EKS clusters for control plane info, nodegroup health, addons, and versions
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/eks-cluster-monitor-$(date +%s).txt"
LOG_FILE="/var/log/eks-cluster-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
NODEGROUP_UNHEALTHY_WARN="${NODEGROUP_UNHEALTHY_WARN:-1}"

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

# API wrappers
list_clusters() {
  aws eks list-clusters --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_cluster() {
  local name="$1"
  aws eks describe-cluster --name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_nodegroups() {
  local name="$1"
  aws eks list-nodegroups --cluster-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_nodegroup() {
  local cluster="$1"; local ng="$2"
  aws eks describe-nodegroup --cluster-name "${cluster}" --nodegroup-name "${ng}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_fargate_profiles() {
  local name="$1"
  aws eks list-fargate-profiles --cluster-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_addons() {
  local name="$1"
  aws eks list-addons --cluster-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_addon() {
  local cluster="$1"; local addon="$2"
  aws eks describe-addon --cluster-name "${cluster}" --addon-name "${addon}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS EKS Cluster Monitor Report"
    echo "==============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Nodegroup Unhealthy Warn Threshold: ${NODEGROUP_UNHEALTHY_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_clusters() {
  log_message INFO "Listing EKS clusters"
  {
    echo "=== EKS CLUSTERS ==="
  } >> "${OUTPUT_FILE}"

  local clusters
  clusters=$(list_clusters)

  local total_clusters=0 clusters_with_unhealthy_nodes=0 cluster_outdated=0

  echo "${clusters}" | jq -r '.clusters[]? ' 2>/dev/null | while read -r cname; do
    ((total_clusters++))
    echo "Cluster: ${cname}" >> "${OUTPUT_FILE}"

    local desc
    desc=$(describe_cluster "${cname}")

    local status endpoint version roleArn created resourcesVpcConfig logging
    status=$(echo "${desc}" | jq_safe '.cluster.status')
    endpoint=$(echo "${desc}" | jq_safe '.cluster.endpoint')
    version=$(echo "${desc}" | jq_safe '.cluster.version')
    roleArn=$(echo "${desc}" | jq_safe '.cluster.roleArn')
    created=$(echo "${desc}" | jq_safe '.cluster.createdAt')
    resourcesVpcConfig=$(echo "${desc}" | jq -c '.cluster.resourcesVpcConfig')
    logging=$(echo "${desc}" | jq -c '.cluster.logging')

    echo "  Status: ${status}" >> "${OUTPUT_FILE}"
    echo "  Endpoint: ${endpoint}" >> "${OUTPUT_FILE}"
    echo "  Kubernetes Version: ${version}" >> "${OUTPUT_FILE}"
    echo "  Role: ${roleArn}" >> "${OUTPUT_FILE}"
    echo "  Created: ${created}" >> "${OUTPUT_FILE}"
    echo "  VPC Config: ${resourcesVpcConfig}" >> "${OUTPUT_FILE}"

    # Logging
    if echo "${logging}" | jq -e '.clusterLogging[]? | select(.enabled==true)' >/dev/null 2>&1; then
      echo "  Control Plane Logging: enabled" >> "${OUTPUT_FILE}"
    else
      echo "  Control Plane Logging: not fully enabled" >> "${OUTPUT_FILE}"
    fi

    # Nodegroups
    local ngs
    ngs=$(list_nodegroups "${cname}")
    local ng_count
    ng_count=$(echo "${ngs}" | jq '.nodegroups | length' 2>/dev/null || echo 0)
    echo "  Nodegroups: ${ng_count}" >> "${OUTPUT_FILE}"

    if (( ng_count > 0 )); then
      echo "  Nodegroup details:" >> "${OUTPUT_FILE}"
      echo "${ngs}" | jq -r '.nodegroups[]?' 2>/dev/null | while read -r ng; do
        local ng_desc
        ng_desc=$(describe_nodegroup "${cname}" "${ng}")
        local ng_status desired_count unhealthy
        ng_status=$(echo "${ng_desc}" | jq_safe '.nodegroup.status')
        desired_count=$(echo "${ng_desc}" | jq_safe '.nodegroup.scalingConfig.desiredSize')
        unhealthy=$(echo "${ng_desc}" | jq '[.nodegroup.resources[]?.autoScalingGroups[]?.instances[]? | select(.lifecycleState!="InService") ] | length' 2>/dev/null || echo 0)

        echo "    - ${ng}: status=${ng_status}, desiredSize=${desired_count}, unhealthyInstances=${unhealthy}" >> "${OUTPUT_FILE}"
        if (( unhealthy >= NODEGROUP_UNHEALTHY_WARN )); then
          ((clusters_with_unhealthy_nodes++))
          echo "      WARNING: Nodegroup ${ng} has ${unhealthy} unhealthy instances" >> "${OUTPUT_FILE}"
        fi
      done
    fi

    # Fargate profiles
    local fps
    fps=$(list_fargate_profiles "${cname}")
    local fp_count
    fp_count=$(echo "${fps}" | jq '.fargateProfileNames | length' 2>/dev/null || echo 0)
    echo "  Fargate Profiles: ${fp_count}" >> "${OUTPUT_FILE}"

    # Add-ons
    local addons
    addons=$(list_addons "${cname}")
    local addon_count
    addon_count=$(echo "${addons}" | jq '.addons | length' 2>/dev/null || echo 0)
    echo "  Add-ons: ${addon_count}" >> "${OUTPUT_FILE}"
    if (( addon_count > 0 )); then
      echo "  Add-on details:" >> "${OUTPUT_FILE}"
      echo "${addons}" | jq -r '.addons[]?' 2>/dev/null | while read -r addon; do
        local a_desc
        a_desc=$(describe_addon "${cname}" "${addon}")
        local addon_version addon_status
        addon_version=$(echo "${a_desc}" | jq_safe '.addon.addonVersion')
        addon_status=$(echo "${a_desc}" | jq_safe '.addon.status')
        echo "    - ${addon}: version=${addon_version}, status=${addon_status}" >> "${OUTPUT_FILE}"
      done
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "EKS Summary:"
    echo "  Total Clusters: ${total_clusters}"
    echo "  Clusters With Unhealthy Nodegroups: ${clusters_with_unhealthy_nodes}"
    echo "  Clusters With Outdated Components: ${cluster_outdated}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local total="$1"; local unhealthy_clusters="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( unhealthy_clusters > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS EKS Cluster Monitor Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Clusters", "value": "${total}", "short": true},
        {"title": "Clusters With Unhealthy Nodegroups", "value": "${unhealthy_clusters}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}

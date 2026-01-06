#!/bin/bash

################################################################################
# AWS Elastic Beanstalk Monitor
# Monitors Elastic Beanstalk applications and environments for health, instances,
# and application version drift.
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/eb-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-elastic-beanstalk-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
UNHEALTHY_WARNING_THRESHOLD="${UNHEALTHY_WARNING_THRESHOLD:-1}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_applications() {
  aws elasticbeanstalk describe-applications --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_environments() {
  local appname="$1"
  aws elasticbeanstalk describe-environments --application-name "${appname}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_environment_resources() {
  local envname="$1"
  aws elasticbeanstalk describe-environment-resources --environment-name "${envname}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_configuration_settings() {
  local appname="$1"; local envname="$2"
  aws elasticbeanstalk describe-configuration-settings --application-name "${appname}" --environment-name "${envname}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Elastic Beanstalk Monitor Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Unhealthy Warning Threshold: ${UNHEALTHY_WARNING_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_environments() {
  log_message INFO "Listing Elastic Beanstalk applications"
  echo "=== Elastic Beanstalk Applications ===" >> "${OUTPUT_FILE}"

  local apps
  apps=$(list_applications)

  local total_envs=0 unhealthy_envs=0

  echo "${apps}" | jq -r '.Applications[]?.ApplicationName' 2>/dev/null | while read -r app; do
    echo "Application: ${app}" >> "${OUTPUT_FILE}"
    local envs
    envs=$(describe_environments "${app}")

    echo "${envs}" | jq -c '.Environments[]?' 2>/dev/null | while read -r env; do
      ((total_envs++))
      local env_name
      env_name=$(echo "${env}" | jq_safe '.EnvironmentName')
      local status health version solution_stack
      status=$(echo "${env}" | jq_safe '.Status')
      health=$(echo "${env}" | jq_safe '.Health')
      version=$(echo "${env}" | jq_safe '.VersionLabel')
      solution_stack=$(echo "${env}" | jq_safe '.SolutionStackName')

      echo "  Environment: ${env_name}" >> "${OUTPUT_FILE}"
      echo "    Status: ${status}" >> "${OUTPUT_FILE}"
      echo "    Health: ${health}" >> "${OUTPUT_FILE}"
      echo "    VersionLabel: ${version}" >> "${OUTPUT_FILE}"
      echo "    SolutionStack: ${solution_stack}" >> "${OUTPUT_FILE}"

      # Resources
      local resources
      resources=$(describe_environment_resources "${env_name}")
      local instance_count
      instance_count=$(echo "${resources}" | jq '.EnvironmentResources.Instances | length' 2>/dev/null || echo 0)
      local lb_names
      lb_names=$(echo "${resources}" | jq -r '.EnvironmentResources.LoadBalancers[]?.Name' 2>/dev/null || echo '')

      echo "    InstanceCount: ${instance_count}" >> "${OUTPUT_FILE}"
      echo "    LoadBalancers: ${lb_names}" >> "${OUTPUT_FILE}"

      # Configuration sniff: check for Rolling updates or managed updates
      local cfg
      cfg=$(describe_configuration_settings "${app}" "${env_name}")
      local rolling_enabled
      rolling_enabled=$(echo "${cfg}" | jq -r '.ConfigurationSettings[]?.OptionSettings[]? | select(.Namespace=="aws:autoscaling:rollingupdate" and .OptionName=="RollingUpdateEnabled") | .Value' 2>/dev/null || echo '')
      if [[ "${rolling_enabled}" == "true" ]]; then
        echo "    RollingUpdate: enabled" >> "${OUTPUT_FILE}"
      else
        echo "    RollingUpdate: not enabled" >> "${OUTPUT_FILE}"
      fi

      # Health check - treat Degraded/Severe/Severe as unhealthy
      if [[ "${health}" =~ (Red|Severe|Degraded|Grey|Severe) || "${status}" == "Terminated" ]]; then
        ((unhealthy_envs++))
        echo "    WARNING: Environment ${env_name} has health=${health} status=${status}" >> "${OUTPUT_FILE}"
      fi

      echo "" >> "${OUTPUT_FILE}"
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "EB Summary:"
    echo "  Total Environments: ${total_envs}"
    echo "  Unhealthy Environments: ${unhealthy_envs}"
    echo ""
  } >> "${OUTPUT_FILE}"

  return 0
}

send_slack_alert() {
  local total="$1"; local unhealthy="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( unhealthy > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Elastic Beanstalk Monitor Report",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Total Environments", "value": "${total}", "short": true},
        {"title": "Unhealthy Environments", "value": "${unhealthy}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
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
  log_message INFO "Starting Elastic Beanstalk monitor"
  write_header
  audit_environments
  log_message INFO "Monitor complete. Report saved to: ${OUTPUT_FILE}"

  local total unhealthy
  total=$(grep "Total Environments:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  unhealthy=$(grep "Unhealthy Environments:" "${OUTPUT_FILE}" | awk '{print $NF}' 2>/dev/null || echo 0)
  send_slack_alert "${total}" "${unhealthy}"
  cat "${OUTPUT_FILE}"
}

main "$@"

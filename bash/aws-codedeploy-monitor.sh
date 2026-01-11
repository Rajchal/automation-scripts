#!/bin/bash

################################################################################
# AWS CodeDeploy Monitor
# Monitors CodeDeploy applications/deployments for failures, in-progress rollbacks,
# and unhealthy instance targets.
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/codedeploy-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-codedeploy-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
FAILURE_WARN_THRESHOLD="${FAILURE_WARN_THRESHOLD:-1}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_applications() {
  aws deploy list-applications --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_deployments_for_app() {
  local app="$1"
  aws deploy list-deployments --application-name "${app}" --region "${REGION}" --include-only-statuses "Created,Queued,InProgress,Failed,Stopped,Succeeded,Ready" --output json 2>/dev/null || echo '{}'
}

describe_deployments() {
  local ids_csv="$1"
  aws deploy batch-get-deployments --deployment-ids ${ids_csv} --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_deployment_targets() {
  local depid="$1"
  aws deploy list-deployment-instances --deployment-id "${depid}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_instance() {
  local instance_id="$1"
  aws ec2 describe-instances --instance-ids "${instance_id}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS CodeDeploy Monitor Report"
    echo "=============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Failure Warn Threshold: ${FAILURE_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_codedeploy() {
  log_message INFO "Listing CodeDeploy applications"
  echo "=== CodeDeploy Applications ===" >> "${OUTPUT_FILE}"

  local apps
  apps=$(list_applications)
  echo "${apps}" | jq -r '.applications[]?' 2>/dev/null | while read -r app; do
    echo "Application: ${app}" >> "${OUTPUT_FILE}"

    local deps
    deps=$(list_deployments_for_app "${app}")
    local dep_ids
    dep_ids=$(echo "${deps}" | jq -r '.deployments[]?' 2>/dev/null | head -n 20 | tr '\n' ' ' || true)

    if [[ -z "${dep_ids// /}" ]]; then
      echo "  No recent deployments" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    local deps_json
    deps_json=$(describe_deployments "${dep_ids}")

    echo "  Recent deployments:" >> "${OUTPUT_FILE}"
    echo "${deps_json}" | jq -c '.deploymentsInfo[]?' 2>/dev/null | while read -r d; do
      local id status create_time complete_time deployment_config
      id=$(echo "${d}" | jq_safe '.deploymentId')
      status=$(echo "${d}" | jq_safe '.status')
      create_time=$(echo "${d}" | jq_safe '.createTime')
      complete_time=$(echo "${d}" | jq_safe '.completeTime')
      deployment_config=$(echo "${d}" | jq_safe '.deploymentOverview')

      echo "    - ${id}: status=${status}, created=${create_time}, completed=${complete_time}" >> "${OUTPUT_FILE}"

      # Check instances for failed or in-progress targets
      local targets
      targets=$(get_deployment_targets "${id}")
      local target_count
      target_count=$(echo "${targets}" | jq '.instanceIds | length' 2>/dev/null || echo 0)
      if (( target_count > 0 )); then
        echo "      Targets: ${target_count}" >> "${OUTPUT_FILE}"
        echo "      Instance details:" >> "${OUTPUT_FILE}"
        echo "${targets}" | jq -r '.instanceIds[]?' 2>/dev/null | while read -r iid; do
          echo "        - InstanceId: ${iid}" >> "${OUTPUT_FILE}"
          # Optionally describe instance
          local inst
          inst=$(describe_instance "${iid}")
          local state
          state=$(echo "${inst}" | jq -r '.Reservations[0].Instances[0].State.Name' 2>/dev/null || echo '')
          echo "          State: ${state}" >> "${OUTPUT_FILE}"
        done
      fi

      if [[ "${status}" == "Failed" || "${status}" == "Stopped" ]]; then
        echo "      WARNING: Deployment ${id} has status=${status}" >> "${OUTPUT_FILE}"
      fi

    done

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "CodeDeploy Summary:"
    echo "  Applications checked: $(echo "${apps}" | jq '.applications | length' 2>/dev/null || echo 0)"
    echo ""
  } >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local app="$1"; local msg="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "CodeDeploy Alert: ${app}",
  "attachments": [
    {"color": "warning", "text": "${msg}"}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting CodeDeploy monitor"
  write_header
  audit_codedeploy
  log_message INFO "CodeDeploy monitoring complete. Report: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

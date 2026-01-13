#!/bin/bash

################################################################################
# AWS SageMaker Monitor
# Monitors SageMaker training jobs, endpoints, notebook instances, and invocation metrics
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/sagemaker-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-sagemaker-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
FAILED_JOB_WARN_THRESHOLD="${FAILED_JOB_WARN_THRESHOLD:-1}"
ENDPOINT_ERROR_RATE_WARN_PCT="${ENDPOINT_ERROR_RATE_WARN_PCT:-1}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_training_jobs() {
  aws sagemaker list-training-jobs --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_training_job() {
  local name="$1"
  aws sagemaker describe-training-job --training-job-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_endpoints() {
  aws sagemaker list-endpoints --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_endpoint() {
  local name="$1"
  aws sagemaker describe-endpoint --endpoint-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_notebook_instances() {
  aws sagemaker list-notebook-instances --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

describe_notebook_instance() {
  local name="$1"
  aws sagemaker describe-notebook-instance --notebook-instance-name "${name}" --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

get_endpoint_invocations_metric() {
  local endpoint="$1"; local stat="$2"; local metric="$3"; local period="300"
  aws cloudwatch get-metric-statistics --namespace AWS/SageMaker --metric-name "${metric}" --dimensions Name=EndpointName,Value="${endpoint}" --start-time "$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period ${period} --statistics ${stat} --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS SageMaker Monitor Report"
    echo "============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_training_jobs() {
  log_message INFO "Listing SageMaker training jobs"
  echo "=== Training Jobs ===" >> "${OUTPUT_FILE}"

  local jobs
  jobs=$(list_training_jobs)
  echo "${jobs}" | jq -r '.TrainingJobSummaries[]?.TrainingJobName' 2>/dev/null | head -n 200 | while read -r j; do
    echo "TrainingJob: ${j}" >> "${OUTPUT_FILE}"
    local desc
    desc=$(describe_training_job "${j}")
    local status
    status=$(echo "${desc}" | jq_safe '.TrainingJobStatus')
    local create_time
    create_time=$(echo "${desc}" | jq_safe '.CreationTime')
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"
    echo "  Created: ${create_time}" >> "${OUTPUT_FILE}"

    if [[ "${status}" == "Failed" ]]; then
      echo "  WARNING: Training job failed" >> "${OUTPUT_FILE}"
    fi
    echo "" >> "${OUTPUT_FILE}"
  done

}

audit_endpoints() {
  log_message INFO "Listing SageMaker endpoints"
  echo "=== Endpoints ===" >> "${OUTPUT_FILE}"

  local eps
  eps=$(list_endpoints)
  echo "${eps}" | jq -c '.Endpoints[]?' 2>/dev/null | while read -r e; do
    local name status config
    name=$(echo "${e}" | jq_safe '.EndpointName')
    status=$(echo "${e}" | jq_safe '.EndpointStatus')
    echo "Endpoint: ${name}" >> "${OUTPUT_FILE}"
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"

    # CloudWatch metrics: InvocationCount, ModelLatency, 4xx/5xx errors
    local inv_count latency_p95 errors_4xx errors_5xx
    inv_count=$(get_endpoint_invocations_metric "${name}" "Sum" "Invocations" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    latency_p95=$(get_endpoint_invocations_metric "${name}" "p95" "ModelLatency" | jq -r '.Datapoints[]?.p95' 2>/dev/null | awk '{print ($1+0)}' | head -n1)
    errors_4xx=$(get_endpoint_invocations_metric "${name}" "Sum" "4XXError" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    errors_5xx=$(get_endpoint_invocations_metric "${name}" "Sum" "5XXError" | jq -r '.Datapoints[]?.Sum' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')

    echo "  Invocations (15m): ${inv_count}" >> "${OUTPUT_FILE}"
    echo "  ModelLatency p95(ms): ${latency_p95:-unknown}" >> "${OUTPUT_FILE}"
    echo "  4XX Errors (15m): ${errors_4xx}" >> "${OUTPUT_FILE}"
    echo "  5XX Errors (15m): ${errors_5xx}" >> "${OUTPUT_FILE}"

    # Simple error-rate alert
    if [[ -n "${inv_count}" && ${inv_count:-0} -gt 0 ]]; then
      local err_pct
      err_pct=$(( (errors_4xx + errors_5xx) * 100 / (inv_count) ))
      if (( err_pct >= ENDPOINT_ERROR_RATE_WARN_PCT )); then
        echo "  WARNING: Endpoint ${name} error rate ${err_pct}% >= ${ENDPOINT_ERROR_RATE_WARN_PCT}%" >> "${OUTPUT_FILE}"
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

audit_notebook_instances() {
  log_message INFO "Listing SageMaker notebook instances"
  echo "=== Notebook Instances ===" >> "${OUTPUT_FILE}"

  local nbs
  nbs=$(list_notebook_instances)
  echo "${nbs}" | jq -c '.NotebookInstances[]?' 2>/dev/null | while read -r n; do
    local name status instance_type
    name=$(echo "${n}" | jq_safe '.NotebookInstanceName')
    status=$(echo "${n}" | jq_safe '.NotebookInstanceStatus')
    instance_type=$(echo "${n}" | jq_safe '.InstanceType')
    echo "Notebook: ${name}" >> "${OUTPUT_FILE}"
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"
    echo "  Type: ${instance_type}" >> "${OUTPUT_FILE}"

    if [[ "${status}" != "InService" && "${status}" != "Stopped" ]]; then
      echo "  WARNING: Notebook ${name} in unexpected status: ${status}" >> "${OUTPUT_FILE}"
    fi
    echo "" >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local subject="$1"; local body="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS SageMaker Monitor: ${subject}",
  "attachments": [
    {"color": "warning", "text": "${body}"}
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting SageMaker monitor"
  write_header
  audit_training_jobs
  audit_endpoints
  audit_notebook_instances
  log_message INFO "SageMaker monitor complete. Report: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

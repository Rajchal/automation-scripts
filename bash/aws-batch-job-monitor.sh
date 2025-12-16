#!/bin/bash

################################################################################
# AWS Batch Job Monitor
# Monitors AWS Batch job queues, jobs, and compute environments
# Detects long-waiting jobs, failed jobs, CE capacity pressure, and misconfigs
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/batch-job-monitor-$(date +%s).txt"
LOG_FILE="/var/log/batch-job-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
# Alert when RUNNABLE jobs wait longer than this many minutes
RUNNABLE_AGE_MINUTES="${RUNNABLE_AGE_MINUTES:-30}"
# Alert when failed jobs exceed this count per queue (recent window)
FAILED_THRESHOLD="${FAILED_THRESHOLD:-5}"
# Max jobs to inspect per status per queue
MAX_JOBS_PER_STATUS="${MAX_JOBS_PER_STATUS:-50}"

################################################################################
# Logging
################################################################################
log_message() {
  local level="$1"; shift
  local message="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

################################################################################
# Helpers
################################################################################
minutes_to_seconds() { echo $(( $1 * 60 )); }

jq_safe() { jq -r "$1" 2>/dev/null || true; }

################################################################################
# Describe job queues
################################################################################
list_job_queues() {
  aws batch describe-job-queues \
    --region "${REGION}" \
    --query 'jobQueues[*]' \
    --output json 2>/dev/null
}

################################################################################
# Describe compute environments
################################################################################
list_compute_envs() {
  aws batch describe-compute-environments \
    --region "${REGION}" \
    --query 'computeEnvironments[*]' \
    --output json 2>/dev/null
}

################################################################################
# List jobs by queue and status
################################################################################
list_jobs() {
  local queue="$1"; local status="$2"
  aws batch list-jobs \
    --region "${REGION}" \
    --job-queue "${queue}" \
    --job-status "${status}" \
    --max-results ${MAX_JOBS_PER_STATUS} \
    --query 'jobSummaryList[*].jobId' \
    --output text 2>/dev/null || true
}

################################################################################
# Describe multiple jobs
################################################################################
describe_jobs() {
  local -a ids=("$@")
  if [[ ${#ids[@]} -eq 0 ]]; then echo '[]'; return 0; fi
  aws batch describe-jobs \
    --region "${REGION}" \
    --jobs "${ids[@]}" \
    --query 'jobs[*]' \
    --output json 2>/dev/null || echo '[]'
}

################################################################################
# Queue overview
################################################################################
report_queues_overview() {
  log_message INFO "Fetching job queues overview"
  local jq_json
  jq_json=$(list_job_queues)
  {
    echo "AWS Batch Job Monitor Report"
    echo "============================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Runnable Age Alert: ${RUNNABLE_AGE_MINUTES} minutes"
    echo "Failed Threshold: ${FAILED_THRESHOLD}"
    echo ""
    echo "=== JOB QUEUES OVERVIEW ==="
  } > "${OUTPUT_FILE}"

  echo "${jq_json}" | jq -c '.[]' | while read -r q; do
    local name state status priority ce_count
    name=$(echo "${q}" | jq_safe '.jobQueueName')
    state=$(echo "${q}" | jq_safe '.state')
    status=$(echo "${q}" | jq_safe '.status')
    priority=$(echo "${q}" | jq_safe '.priority')
    ce_count=$(echo "${q}" | jq '.computeEnvironmentOrder | length')
    {
      echo "Queue: ${name}"
      echo "  State: ${state}"
      echo "  Status: ${status}"
      echo "  Priority: ${priority}"
      echo "  Attached Compute Environments: ${ce_count}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

################################################################################
# Compute environments analysis
################################################################################
report_compute_envs() {
  log_message INFO "Analyzing compute environments"
  {
    echo "=== COMPUTE ENVIRONMENTS ==="
  } >> "${OUTPUT_FILE}"

  local ce_json
  ce_json=$(list_compute_envs)
  echo "${ce_json}" | jq -c '.[]' | while read -r ce; do
    local name type state status cr_type desired min max inst_types alloc_strategy
    name=$(echo "${ce}" | jq_safe '.computeEnvironmentName')
    type=$(echo "${ce}" | jq_safe '.type')
    state=$(echo "${ce}" | jq_safe '.state')
    status=$(echo "${ce}" | jq_safe '.status')
    cr_type=$(echo "${ce}" | jq_safe '.computeResources.type')
    desired=$(echo "${ce}" | jq_safe '.computeResources.desiredvCpus')
    min=$(echo "${ce}" | jq_safe '.computeResources.minvCpus')
    max=$(echo "${ce}" | jq_safe '.computeResources.maxvCpus')
    inst_types=$(echo "${ce}" | jq -r '.computeResources.instanceTypes | join(",")')
    alloc_strategy=$(echo "${ce}" | jq_safe '.computeResources.allocationStrategy')
    {
      echo "CE: ${name}"
      echo "  Type: ${type}"
      echo "  State/Status: ${state}/${status}"
      echo "  Compute Type: ${cr_type}"
      echo "  vCPUs: desired=${desired} min=${min} max=${max}"
      echo "  Instance Types: ${inst_types:-N/A}"
      echo "  Allocation Strategy: ${alloc_strategy:-N/A}"
    } >> "${OUTPUT_FILE}"

    # Capacity pressure heuristic: desired == max often signals saturation
    if [[ -n "${desired}" && -n "${max}" ]] && [[ "${desired}" != "null" && "${max}" != "null" ]]; then
      if (( desired >= max )); then
        echo "  WARNING: CE at capacity (desired >= max)" >> "${OUTPUT_FILE}"
      fi
    fi
    echo "" >> "${OUTPUT_FILE}"
  done
}

################################################################################
# Per-queue job status and anomalies
################################################################################
report_queue_jobs() {
  log_message INFO "Evaluating jobs per queue"
  {
    echo "=== QUEUE JOB STATUS ==="
  } >> "${OUTPUT_FILE}"

  local jq_json
  jq_json=$(list_job_queues)
  echo "${jq_json}" | jq -r '.[].jobQueueName' | while read -r queue; do
    [[ -z "${queue}" ]] && continue

    local runnable_ids running_ids succeeded_ids failed_ids
    runnable_ids=$(list_jobs "${queue}" RUNNABLE)
    running_ids=$(list_jobs "${queue}" RUNNING)
    succeeded_ids=$(list_jobs "${queue}" SUCCEEDED)
    failed_ids=$(list_jobs "${queue}" FAILED)

    local runnable_count running_count succeeded_count failed_count
    runnable_count=$(wc -w <<<"${runnable_ids}" | xargs || echo 0)
    running_count=$(wc -w <<<"${running_ids}" | xargs || echo 0)
    succeeded_count=$(wc -w <<<"${succeeded_ids}" | xargs || echo 0)
    failed_count=$(wc -w <<<"${failed_ids}" | xargs || echo 0)

    {
      echo "Queue: ${queue}"
      echo "  RUNNABLE: ${runnable_count}"
      echo "  RUNNING: ${running_count}"
      echo "  SUCCEEDED: ${succeeded_count}"
      echo "  FAILED: ${failed_count}"
    } >> "${OUTPUT_FILE}"

    # Alert on failed threshold
    if (( failed_count >= FAILED_THRESHOLD )); then
      echo "  WARNING: High failures (>= ${FAILED_THRESHOLD})" >> "${OUTPUT_FILE}"
    fi

    # Inspect aging RUNNABLE jobs
    if (( runnable_count > 0 )); then
      local runnable_json aging_threshold
      aging_threshold=$(minutes_to_seconds ${RUNNABLE_AGE_MINUTES})
      runnable_json=$(describe_jobs ${runnable_ids})
      local old_count=0
      echo "${runnable_json}" | jq -c '.[]' | while read -r j; do
        local jid cname created_at age_s
        jid=$(echo "${j}" | jq_safe '.jobId')
        cname=$(echo "${j}" | jq_safe '.jobName')
        created_at=$(echo "${j}" | jq -r '.createdAt // 0')
        if [[ "${created_at}" == "null" || -z "${created_at}" ]]; then created_at=0; fi
        if (( created_at > 0 )); then
          age_s=$(( $(date +%s) - created_at/1000 ))
          if (( age_s >= aging_threshold )); then
            ((old_count++))
            {
              echo "    OLD RUNNABLE: ${cname} (${jid})"
              echo "      Wait Age: ${age_s}s"
            } >> "${OUTPUT_FILE}"
          fi
        fi
      done
      if (( old_count > 0 )); then
        echo "  WARNING: ${old_count} old RUNNABLE jobs (>${RUNNABLE_AGE_MINUTES}m)" >> "${OUTPUT_FILE}"
      fi
    fi

    # Show a few failed job reasons
    if (( failed_count > 0 )); then
      local failed_json
      failed_json=$(describe_jobs ${failed_ids})
      {
        echo "  Recent Failed Samples:" 
      } >> "${OUTPUT_FILE}"
      echo "${failed_json}" | jq -c '.[]' | head -3 | while read -r j; do
        local jid jname reason exit_code
        jid=$(echo "${j}" | jq_safe '.jobId')
        jname=$(echo "${j}" | jq_safe '.jobName')
        reason=$(echo "${j}" | jq_safe '.statusReason')
        exit_code=$(echo "${j}" | jq -r '.container.exitCode // "N/A"')
        {
          echo "    ${jname} (${jid})"
          echo "      ExitCode: ${exit_code}"
          echo "      Reason: ${reason}"
        } >> "${OUTPUT_FILE}"
      done
    fi

    echo "" >> "${OUTPUT_FILE}"
  done
}

################################################################################
# Slack Notification
################################################################################
send_slack_alert() {
  local queues="$1"; local issues="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Batch Job Monitor",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Queues", "value": "${queues}", "short": true},
        {"title": "Issues", "value": "${issues}", "short": true},
        {"title": "Runnable Age Threshold", "value": "${RUNNABLE_AGE_MINUTES}m", "short": true},
        {"title": "Failed Threshold", "value": "${FAILED_THRESHOLD}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

################################################################################
# Main
################################################################################
main() {
  log_message INFO "Starting AWS Batch monitoring"
  report_queues_overview
  report_compute_envs
  report_queue_jobs

  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
  local queue_count issue_count
  queue_count=$(aws batch describe-job-queues --region "${REGION}" --query 'length(jobQueues)' --output text 2>/dev/null || echo 0)
  issue_count=$(grep -c "WARNING" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${queue_count}" "${issue_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

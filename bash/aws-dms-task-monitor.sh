#!/bin/bash

################################################################################
# AWS DMS Task Monitor
# Monitors DMS replication instances and tasks for health, lag, and failures
# Collects CloudWatch metrics and emits a compact audit report with alerts
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/dms-task-monitor-$(date +%s).txt"
LOG_FILE="/var/log/dms-task-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
LAG_WARN_SEC="${LAG_WARN_SEC:-300}"         # warn if CDC lag (src/target) exceeds N seconds
LOOKBACK_HOURS="${LOOKBACK_HOURS:-1}"        # metrics lookback window
EVENTS_LOOKBACK_MIN="${EVENTS_LOOKBACK_MIN:-1440}"  # DMS events lookback in minutes (24h)

# Logging
log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

# Helpers
jq_safe() { jq -r "$1" 2>/dev/null || true; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
start_iso() { date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S; }

# API wrappers
get_replication_instances() {
  aws dms describe-replication-instances \
    --region "${REGION}" \
    --query 'ReplicationInstances[*]' \
    --output json 2>/dev/null || echo '[]'
}

get_replication_tasks() {
  aws dms describe-replication-tasks \
    --region "${REGION}" \
    --without-settings \
    --query 'ReplicationTasks[*]' \
    --output json 2>/dev/null || echo '[]'
}

get_events() {
  aws dms describe-events \
    --region "${REGION}" \
    --duration ${EVENTS_LOOKBACK_MIN} \
    --source-type replication-task \
    --query 'Events[*]' \
    --output json 2>/dev/null || echo '[]'
}

cw_metric_task() {
  local task_id="$1"; local metric="$2"; local stat="${3:-Average}"; local period=300
  aws cloudwatch get-metric-statistics \
    --namespace 'AWS/DMS' \
    --metric-name "${metric}" \
    --dimensions Name=ReplicationTaskIdentifier,Value="${task_id}" \
    --start-time "$(start_iso)" \
    --end-time "$(now_iso)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].Maximum' \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{ if(n>0) printf("%d", sum/n); }'
}

cw_metric_instance() {
  local inst_id="$1"; local metric="$2"; local stat="${3:-Average}"; local period=300
  aws cloudwatch get-metric-statistics \
    --namespace 'AWS/DMS' \
    --metric-name "${metric}" \
    --dimensions Name=ReplicationInstanceIdentifier,Value="${inst_id}" \
    --start-time "$(start_iso)" \
    --end-time "$(now_iso)" \
    --period ${period} \
    --statistics ${stat} \
    --region "${REGION}" \
    --query 'Datapoints[*].Maximum' \
    --output text 2>/dev/null | awk 'NF{sum+=$1; n++} END{ if(n>0) printf("%d", sum/n); }'
}

write_header() {
  {
    echo "AWS DMS Task Monitoring Report"
    echo "==============================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Metrics Lookback: ${LOOKBACK_HOURS}h"
    echo "Lag Warning Threshold: ${LAG_WARN_SEC}s"
    echo "Events Lookback: ${EVENTS_LOOKBACK_MIN} minutes"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_instances() {
  log_message INFO "Reporting replication instances"
  {
    echo "=== REPLICATION INSTANCES ==="
  } >> "${OUTPUT_FILE}"
  local instances
  instances=$(get_replication_instances)
  echo "${instances}" | jq -c '.[]' | while read -r inst; do
    local id status eng ver storage pub create
    id=$(echo "${inst}" | jq_safe '.ReplicationInstanceIdentifier')
    status=$(echo "${inst}" | jq_safe '.ReplicationInstanceStatus')
    eng=$(echo "${inst}" | jq_safe '.EngineVersion')
    ver=$(echo "${inst}" | jq_safe '.EngineVersion')
    storage=$(echo "${inst}" | jq_safe '.AllocatedStorage')
    pub=$(echo "${inst}" | jq_safe '.PubliclyAccessible')
    create=$(echo "${inst}" | jq_safe '.InstanceCreateTime')

    # CPU metric
    local cpu
    cpu=$(cw_metric_instance "${id}" 'CPUUtilization' 'Average' || true)

    {
      echo "Instance: ${id}"
      echo "  Status: ${status}"
      echo "  Engine Version: ${eng}"
      echo "  Allocated Storage: ${storage} GB"
      echo "  Publicly Accessible: ${pub}"
      echo "  Created: ${create}"
      [[ -n "${cpu}" ]] && echo "  Avg CPU (last ${LOOKBACK_HOURS}h): ${cpu}%"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

report_tasks() {
  log_message INFO "Reporting replication tasks and lag"
  {
    echo "=== REPLICATION TASKS ==="
  } >> "${OUTPUT_FILE}"

  local tasks
  tasks=$(get_replication_tasks)
  local warn_count=0 failed_count=0 stopped_count=0 total=0

  echo "${tasks}" | jq -c '.[]' | while read -r t; do
    ((total++))
    local id arn status mig stop_reason srcArn tgtArn create
    id=$(echo "${t}" | jq_safe '.ReplicationTaskIdentifier')
    arn=$(echo "${t}" | jq_safe '.ReplicationTaskArn')
    status=$(echo "${t}" | jq_safe '.Status')
    mig=$(echo "${t}" | jq_safe '.MigrationType')
    stop_reason=$(echo "${t}" | jq_safe '.StopReason')
    srcArn=$(echo "${t}" | jq_safe '.SourceEndpointArn')
    tgtArn=$(echo "${t}" | jq_safe '.TargetEndpointArn')
    create=$(echo "${t}" | jq_safe '.ReplicationTaskCreationDate')

    # Lag metrics (seconds)
    local cdc_src cdc_tgt full_rows
    cdc_src=$(cw_metric_task "${id}" 'CDCLatencySource' 'Maximum' || true)
    cdc_tgt=$(cw_metric_task "${id}" 'CDCLatencyTarget' 'Maximum' || true)
    full_rows=$(cw_metric_task "${id}" 'FullLoadThroughputRowsTarget' 'Maximum' || true)

    {
      echo "Task: ${id}"
      echo "  Status: ${status}  Type: ${mig}"
      echo "  Created: ${create}"
      echo "  Source: ${srcArn}"
      echo "  Target: ${tgtArn}"
      [[ -n "${stop_reason}" && "${stop_reason}" != "null" ]] && echo "  StopReason: ${stop_reason}"
      [[ -n "${cdc_src}" ]] && echo "  CDC Latency Source (max): ${cdc_src}s"
      [[ -n "${cdc_tgt}" ]] && echo "  CDC Latency Target (max): ${cdc_tgt}s"
      [[ -n "${full_rows}" ]] && echo "  FullLoad Rows/sec (max): ${full_rows}"
    } >> "${OUTPUT_FILE}"

    # Flags
    if [[ "${status}" == "failed" || "${status}" == "error" || "${status}" == "stopped" ]]; then
      [[ "${status}" == "stopped" ]] && ((stopped_count++)) || ((failed_count++))
      echo "  WARNING: Unhealthy status: ${status}" >> "${OUTPUT_FILE}"
    fi
    if [[ -n "${cdc_src}" ]] && [[ ${cdc_src:-0} -ge ${LAG_WARN_SEC} ]]; then
      ((warn_count++))
      echo "  WARNING: High CDC source lag (>${LAG_WARN_SEC}s)" >> "${OUTPUT_FILE}"
    fi
    if [[ -n "${cdc_tgt}" ]] && [[ ${cdc_tgt:-0} -ge ${LAG_WARN_SEC} ]]; then
      ((warn_count++))
      echo "  WARNING: High CDC target lag (>${LAG_WARN_SEC}s)" >> "${OUTPUT_FILE}"
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Tasks Summary:"
    echo "  Total: ${total}"
    echo "  Failed: ${failed_count}"
    echo "  Stopped: ${stopped_count}"
    echo "  High-Lag Flags: ${warn_count}"
    echo ""
  } >> "${OUTPUT_FILE}"
}

report_recent_events() {
  log_message INFO "Collecting recent DMS task events"
  {
    echo "=== RECENT TASK EVENTS (last ${EVENTS_LOOKBACK_MIN}m) ==="
  } >> "${OUTPUT_FILE}"
  local events
  events=$(get_events)
  if [[ -z "${events}" || "${events}" == "[]" ]]; then
    echo "No recent events" >> "${OUTPUT_FILE}"
    echo "" >> "${OUTPUT_FILE}"
    return 0
  fi
  echo "${events}" | jq -c '.[]' | head -20 | while read -r e; do
    local date msg src type cat
    date=$(echo "${e}" | jq_safe '.Date')
    msg=$(echo "${e}" | jq_safe '.Message')
    src=$(echo "${e}" | jq_safe '.SourceIdentifier')
    type=$(echo "${e}" | jq_safe '.SourceType')
    cat=$(echo "${e}" | jq_safe '.EventCategories | join(",")')
    {
      echo "Event: ${date}  [${type}] ${src}"
      echo "  Categories: ${cat}"
      echo "  Message: ${msg}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

send_slack_alert() {
  local inst_count="$1"; local task_count="$2"; local issues="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS DMS Task Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Instances", "value": "${inst_count}", "short": true},
        {"title": "Tasks", "value": "${task_count}", "short": true},
        {"title": "Warnings/Failures", "value": "${issues}", "short": true},
        {"title": "Lag Threshold", "value": "${LAG_WARN_SEC}s", "short": true},
        {"title": "Metrics Window", "value": "${LOOKBACK_HOURS}h", "short": true},
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
  log_message INFO "Starting AWS DMS task monitoring"
  write_header
  report_instances
  report_tasks
  report_recent_events
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"

  local inst_count task_count issue_count
  inst_count=$(aws dms describe-replication-instances --region "${REGION}" --query 'length(ReplicationInstances)' --output text 2>/dev/null || echo 0)
  task_count=$(aws dms describe-replication-tasks --region "${REGION}" --query 'length(ReplicationTasks)' --output text 2>/dev/null || echo 0)
  issue_count=$(grep -c "WARNING" "${OUTPUT_FILE}" || echo 0)
  send_slack_alert "${inst_count}" "${task_count}" "${issue_count}"
  cat "${OUTPUT_FILE}"
}

main "$@"

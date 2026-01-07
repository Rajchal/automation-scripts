#!/bin/bash

################################################################################
# AWS CodeBuild Project Monitor
# Reports on CodeBuild projects, recent build failures, average durations, and stuck builds
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/codebuild-monitor-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-codebuild-monitor.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
FAILURE_WARN_THRESHOLD="${FAILURE_WARN_THRESHOLD:-1}" # number of failed builds in last 24h to warn

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_projects() {
  aws codebuild list-projects --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

batch_get_projects() {
  local projects_csv="$1"
  aws codebuild batch-get-projects --names ${projects_csv} --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

list_builds_for_project() {
  local project="$1"
  aws codebuild list-builds-for-project --project-name "${project}" --region "${REGION}" --sort-order "DESCENDING" --output json 2>/dev/null || echo '{}'
}

batch_get_builds() {
  local ids_csv="$1"
  aws codebuild batch-get-builds --ids ${ids_csv} --region "${REGION}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS CodeBuild Project Monitor Report"
    echo "===================================="
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Failure Warn Threshold (24h): ${FAILURE_WARN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_projects() {
  log_message INFO "Listing CodeBuild projects"
  echo "=== CodeBuild Projects ===" >> "${OUTPUT_FILE}"

  local projects
  projects=$(list_projects)

  echo "${projects}" | jq -r '.projects[]?' 2>/dev/null | while read -r proj; do
    echo "Project: ${proj}" >> "${OUTPUT_FILE}"

    # Recent builds
    local builds
    builds=$(list_builds_for_project "${proj}")
    local build_ids
    build_ids=$(echo "${builds}" | jq -r '.ids[]?' 2>/dev/null | head -n 20 | tr '\n' ' ' || true)
    if [[ -z "${build_ids// /}" ]]; then
      echo "  No recent builds" >> "${OUTPUT_FILE}"
      echo "" >> "${OUTPUT_FILE}"
      continue
    fi

    local builds_json
    builds_json=$(batch_get_builds "${build_ids}")

    # summarize last 24h failures and average duration
    local now24
    now24=$(date -u -d '24 hours ago' +%s)
    local fail_count=0 total_count=0 total_duration=0

    echo "  Recent builds:" >> "${OUTPUT_FILE}"
    echo "${builds_json}" | jq -c '.builds[]?' 2>/dev/null | while read -r b; do
      local id status start end duration
      id=$(echo "${b}" | jq_safe '.id')
      status=$(echo "${b}" | jq_safe '.buildStatus')
      start=$(echo "${b}" | jq_safe '.startTime')
      end=$(echo "${b}" | jq_safe '.endTime')

      # compute duration seconds
      if [[ -n "${start}" && "${start}" != "null" && -n "${end}" && "${end}" != "null" ]]; then
        local s e
        s=$(date -u -d "${start}" +%s 2>/dev/null || echo 0)
        e=$(date -u -d "${end}" +%s 2>/dev/null || echo 0)
        duration=$(( e - s ))
      else
        duration=0
      fi

      echo "    - ${id}: status=${status}, duration=${duration}s" >> "${OUTPUT_FILE}"

      # check within 24h window
      if [[ -n "${end}" && "${end}" != "null" ]]; then
        local end_ts
        end_ts=$(date -u -d "${end}" +%s 2>/dev/null || echo 0)
        if (( end_ts >= now24 )); then
          ((total_count++))
          total_duration=$(( total_duration + duration ))
          if [[ "${status}" == "FAILED" || "${status}" == "FAULT" || "${status}" == "TIMED_OUT" ]]; then
            ((fail_count++))
          fi
        fi
      fi
    done

    if (( total_count > 0 )); then
      local avg_duration
      avg_duration=$(( total_duration / total_count ))
      echo "  Last 24h: builds=${total_count}, failures=${fail_count}, avg_duration=${avg_duration}s" >> "${OUTPUT_FILE}"
      if (( fail_count >= FAILURE_WARN_THRESHOLD )); then
        echo "  WARNING: ${fail_count} failed builds in last 24h" >> "${OUTPUT_FILE}"
      fi
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  return 0
}

send_slack_alert() {
  local project="$1"; local fails="$2"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( fails > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "CodeBuild Project Alert: ${project}",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Project", "value": "${project}", "short": true},
        {"title": "Failures (24h)", "value": "${fails}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert for ${project}"
}

main() {
  log_message INFO "Starting CodeBuild project monitor"
  write_header
  audit_projects
  log_message INFO "CodeBuild monitor complete. Report: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

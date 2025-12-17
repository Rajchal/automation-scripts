#!/bin/bash

################################################################################
# AWS WorkSpaces Monitor
# Monitors WorkSpaces health, directories, connection status, and usage hints
# Flags unavailable WorkSpaces, failing connections, and monthly/hourly cost modes
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/workspaces-monitor-$(date +%s).txt"
LOG_FILE="/var/log/workspaces-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
UNAVAILABLE_THRESHOLD="${UNAVAILABLE_THRESHOLD:-1}"   # alert if >= this many unavailable
FAILED_CONN_THRESHOLD="${FAILED_CONN_THRESHOLD:-3}"    # alert if >= this many failed connections in sample

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

# API wrappers
list_directories() {
  aws workspaces describe-workspace-directories \
    --region "${REGION}" \
    --query 'Directories[*]' \
    --output json 2>/dev/null || echo '[]'
}

list_workspaces() {
  aws workspaces describe-workspaces \
    --region "${REGION}" \
    --query 'Workspaces[*]' \
    --output json 2>/dev/null || echo '[]'
}

list_connection_status() {
  aws workspaces describe-workspace-connection-status \
    --region "${REGION}" \
    --query 'WorkspacesConnectionStatus[*]' \
    --output json 2>/dev/null || echo '[]'
}

# Sections
write_header() {
  {
    echo "AWS WorkSpaces Monitoring Report"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Unavailable Threshold: ${UNAVAILABLE_THRESHOLD}"
    echo "Failed Connection Threshold: ${FAILED_CONN_THRESHOLD}"
    echo ""
  } > "${OUTPUT_FILE}"
}

report_directories() {
  log_message INFO "Collecting directories"
  {
    echo "=== DIRECTORIES ==="
  } >> "${OUTPUT_FILE}"
  list_directories | jq -c '.[]' | while read -r d; do
    local id name state subnet type reg_status
    id=$(echo "${d}" | jq_safe '.DirectoryId')
    name=$(echo "${d}" | jq_safe '.DirectoryName')
    state=$(echo "${d}" | jq_safe '.State')
    subnet=$(echo "${d}" | jq -r '.SubnetIds | join(",")')
    type=$(echo "${d}" | jq_safe '.WorkspaceCreationProperties.ComputeType')
    reg_status=$(echo "${d}" | jq_safe '.WorkspaceCreationProperties.UserEnabledAsLocalAdministrator')
    {
      echo "Directory: ${id}"
      echo "  Name: ${name}"
      echo "  State: ${state}"
      echo "  Subnets: ${subnet}"
      echo "  Default ComputeType: ${type}"
      echo "  Local Admin Enabled: ${reg_status}"
      echo ""
    } >> "${OUTPUT_FILE}"
  done
}

report_workspaces() {
  log_message INFO "Collecting WorkSpaces"
  {
    echo "=== WORKSPACES ==="
  } >> "${OUTPUT_FILE}"

  local ws_json unavailable_count hourly_count monthly_count stopped_count
  ws_json=$(list_workspaces)
  unavailable_count=0; hourly_count=0; monthly_count=0; stopped_count=0

  echo "${ws_json}" | jq -c '.[]' | while read -r w; do
    local id user state mode bundle dir
    id=$(echo "${w}" | jq_safe '.WorkspaceId')
    user=$(echo "${w}" | jq_safe '.UserName')
    state=$(echo "${w}" | jq_safe '.State')
    mode=$(echo "${w}" | jq_safe '.WorkspaceProperties.RunningMode')
    bundle=$(echo "${w}" | jq_safe '.BundleId')
    dir=$(echo "${w}" | jq_safe '.DirectoryId')

    case "${mode}" in
      ALWAYS_ON) ((monthly_count++));;
      AUTO_STOP) ((hourly_count++));;
    esac
    [[ "${state}" == "UNHEALTHY" || "${state}" == "ERROR" ]] && ((unavailable_count++))
    [[ "${state}" == "STOPPED" ]] && ((stopped_count++))

    {
      echo "Workspace: ${id}"
      echo "  User: ${user}"
      echo "  State: ${state}"
      echo "  RunningMode: ${mode}"
      echo "  Directory: ${dir}"
      echo "  Bundle: ${bundle}"
    } >> "${OUTPUT_FILE}"

    if [[ "${state}" == "UNHEALTHY" || "${state}" == "ERROR" ]]; then
      echo "  WARNING: Workspace unavailable" >> "${OUTPUT_FILE}"
    fi
    echo "" >> "${OUTPUT_FILE}"
  done

  {
    echo "Workspace Summary:"
    echo "  Total: $(echo "${ws_json}" | jq 'length')"
    echo "  Unavailable: ${unavailable_count}"
    echo "  Stopped: ${stopped_count}"
    echo "  Monthly (ALWAYS_ON): ${monthly_count}"
    echo "  Hourly (AUTO_STOP): ${hourly_count}"
    echo ""
  } >> "${OUTPUT_FILE}"

  if (( unavailable_count >= UNAVAILABLE_THRESHOLD )); then
    log_message WARN "Unavailable WorkSpaces: ${unavailable_count}"
  fi
}

report_connection_status() {
  log_message INFO "Checking connection status"
  {
    echo "=== CONNECTION STATUS (sample) ==="
  } >> "${OUTPUT_FILE}"

  local conn_json failed_count
  conn_json=$(list_connection_status)
  failed_count=0

  echo "${conn_json}" | jq -c '.[]' | head -50 | while read -r c; do
    local id status conn_state reason last
    id=$(echo "${c}" | jq_safe '.WorkspaceId')
    status=$(echo "${c}" | jq_safe '.ConnectionState')
    conn_state=$(echo "${c}" | jq_safe '.ConnectionStateCheckTimestamp')
    reason=$(echo "${c}" | jq_safe '.LastKnownUserConnectionStatus')
    last=$(echo "${c}" | jq_safe '.LastKnownUserConnectionTimestamp')
    {
      echo "Workspace: ${id}"
      echo "  ConnectionState: ${status}"
      echo "  StateCheckedAt: ${conn_state}"
      echo "  LastUserConnStatus: ${reason}"
      echo "  LastUserConnTime: ${last}"
    } >> "${OUTPUT_FILE}"

    if [[ "${status}" == "FAILED" || "${status}" == "DISCONNECTED" ]]; then
      ((failed_count++))
      echo "  WARNING: Connection issue" >> "${OUTPUT_FILE}"
    fi
    echo "" >> "${OUTPUT_FILE}"
  done

  if (( failed_count >= FAILED_CONN_THRESHOLD )); then
    log_message WARN "Connection issues: ${failed_count} in sample"
  fi
}

send_slack_alert() {
  local total="$1"; local unavailable="$2"; local failed_conn="$3"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local payload
  payload=$(cat <<EOF
{
  "text": "AWS WorkSpaces Monitoring Report",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "WorkSpaces", "value": "${total}", "short": true},
        {"title": "Unavailable", "value": "${unavailable}", "short": true},
        {"title": "Conn Issues (sample)", "value": "${failed_conn}", "short": true},
        {"title": "Unavailable Threshold", "value": "${UNAVAILABLE_THRESHOLD}", "short": true},
        {"title": "Conn Threshold", "value": "${FAILED_CONN_THRESHOLD}", "short": true},
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
  log_message INFO "Starting AWS WorkSpaces monitoring"
  write_header
  report_directories
  report_workspaces
  report_connection_status

  local total unavailable failed_conn
  total=$(aws workspaces describe-workspaces --region "${REGION}" --query 'length(Workspaces)' --output text 2>/dev/null || echo 0)
  unavailable=$(grep -c "Workspace unavailable" "${OUTPUT_FILE}" || echo 0)
  failed_conn=$(grep -c "Connection issue" "${OUTPUT_FILE}" || echo 0)

  send_slack_alert "${total}" "${unavailable}" "${failed_conn}"
  log_message INFO "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
  cat "${OUTPUT_FILE}"
}

main "$@"

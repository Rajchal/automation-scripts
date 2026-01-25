#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/aws-ssm-patch-compliance-monitor.log"
REPORT_FILE="/tmp/ssm-patch-compliance-monitor-$(date +%Y%m%d%H%M%S).txt"

REGION="${AWS_REGION:-${REGION:-us-east-1}}"
MAX_RESULTS="${SSM_MAX_RESULTS:-100}"
COMPLIANCE_THRESHOLD="${SSM_COMPLIANCE_THRESHOLD:-90}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >> "$LOG_FILE"
}

send_slack_alert() {
  if [ -n "$SLACK_WEBHOOK" ]; then
    payload=$(jq -n --arg t "$1" '{"text":$t}')
    curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
  fi
}

write_header() {
  echo "SSM Patch Compliance Report - $(date -u)" > "$REPORT_FILE"
  echo "Region: $REGION" >> "$REPORT_FILE"
  echo "Compliance threshold: $COMPLIANCE_THRESHOLD%" >> "$REPORT_FILE"
  echo "" >> "$REPORT_FILE"
}

calc_percent() {
  local num=$1
  local den=$2
  if [ "$den" -eq 0 ]; then
    echo 0
  else
    awk "BEGIN {printf \"%.0f\", ($num / $den) * 100}"
  fi
}

main() {
  write_header

  states_json=$(aws ssm describe-instance-patch-states --max-items "$MAX_RESULTS" --region "$REGION" --output json 2>/dev/null || echo '{"InstancePatchStates":[]}')
  entries=$(echo "$states_json" | jq -c '.InstancePatchStates[]?')

  if [ -z "$entries" ]; then
    echo "No SSM patch state data found." >> "$REPORT_FILE"
    log_message "No SSM patch states in region $REGION"
    exit 0
  fi

  total=0
  noncompliant=0

  echo "$states_json" | jq -c '.InstancePatchStates[]?' | while read -r item; do
    total=$((total+1))
    instance_id=$(echo "$item" | jq -r '.InstanceId // "<no-id>"')
    missing=$(echo "$item" | jq -r '.MissingCount // 0')
    failed=$(echo "$item" | jq -r '.FailedCount // 0')
    installed=$(echo "$item" | jq -r '.InstalledCount // 0')
    installed_other=$(echo "$item" | jq -r '.InstalledOtherCount // 0')

    denom=$((installed + missing + failed + installed_other))
    pct=$(calc_percent "$installed" "$denom")

    echo "Instance: $instance_id" >> "$REPORT_FILE"
    echo "Installed: $installed, Missing: $missing, Failed: $failed, InstalledOther: $installed_other" >> "$REPORT_FILE"
    echo "Compliance: $pct%" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    if [ "$missing" -gt 0 ] || [ "$failed" -gt 0 ] || [ "$pct" -lt "$COMPLIANCE_THRESHOLD" ]; then
      send_slack_alert "SSM Patch Alert: Instance $instance_id compliance=$pct% missing=$missing failed=$failed"
      noncompliant=$((noncompliant+1))
    fi
  done

  echo "Summary: total_instances=$total, noncompliant=$noncompliant" >> "$REPORT_FILE"
  log_message "SSM patch report written to $REPORT_FILE (total=$total, noncompliant=$noncompliant)"
}

main "$@"
#!/bin/bash

################################################################################
# AWS SSM Patch Compliance Monitor
# Audits managed instances for patch compliance: compliance summaries, per-
# instance non-compliant counts, OS/platform, missing critical/security patches,
# recent patch state, and SSM agent version. Pulls AWS/SSMCompliance metrics if
# available. Includes thresholds, logging, Slack/email alerts, and a text
# report.
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/ssm-patch-compliance-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/ssm-patch-compliance.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
EMAIL_TO="${EMAIL_TO:-}"
PROFILE="${AWS_PROFILE:-}"

# Thresholds
NONCOMPLIANT_WARN="${NONCOMPLIANT_WARN:-1}"       # non-compliant items per instance
CRITICAL_MISSING_WARN="${CRITICAL_MISSING_WARN:-1}" # critical/security missing count
LOOKBACK_HOURS="${LOOKBACK_HOURS:-24}"
METRIC_PERIOD="${METRIC_PERIOD:-300}"

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_INSTANCES=0
INSTANCES_NONCOMPLIANT=0
INSTANCES_CRITICAL_MISSING=0
INSTANCES_AGENT_OUTDATED=0

ISSUES=()

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

aws_cmd() {
  if [[ -n "${PROFILE}" ]]; then AWS_PROFILE="${PROFILE}" aws "$@"; else aws "$@"; fi
}

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
      "title": "AWS SSM Patch Compliance Alert",
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

date_to_age_hours() {
  local d="$1"
  [[ -z "$d" || "$d" == "null" ]] && { echo 999999; return; }
  local now ts
  now=$(date -u +%s)
  ts=$(date -u -d "$d" +%s 2>/dev/null || echo 0)
  [[ "$ts" == "0" ]] && { echo 999999; return; }
  echo $(( (now - ts) / 3600 ))
}

record_issue() {
  ISSUES+=("$1")
}

write_header() {
  {
    echo "AWS SSM Patch Compliance Monitor"
    echo "================================"
    echo "Generated: $(date)"
    echo "Region: ${REGION}"
    echo "Thresholds:"
    echo "  Non-compliant items warning: >= ${NONCOMPLIANT_WARN}"
    echo "  Critical/security missing warning: >= ${CRITICAL_MISSING_WARN}"
    echo ""
  } > "${OUTPUT_FILE}"
}

list_instances() {
  aws_cmd ssm describe-instance-information \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"InstanceInformationList":[]}'
}

list_compliance() {
  aws_cmd ssm list-compliance-items \
    --filters Key=ComplianceType,Values=Patch \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ComplianceItems":[]}'
}

get_compliance_summary() {
  aws_cmd ssm list-compliance-summaries \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ComplianceSummaryItems":[]}'
}

get_instance_compliance() {
  local instance_id="$1"
  aws_cmd ssm list-compliance-items \
    --filters Key=ComplianceType,Values=Patch Key=ResourceId,Values="$instance_id" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"ComplianceItems":[]}'
}

get_agent_version() {
  local instance_id="$1"
  aws_cmd ssm describe-instance-information \
    --filters Key=InstanceIds,Values="$instance_id" \
    --region "${REGION}" \
    --output json 2>/dev/null | jq -r '.InstanceInformationList[0].AgentVersion // ""'
}

get_metrics() {
  local instance_id="$1" metric="$2" stat_type="${3:-Sum}"
  aws_cmd cloudwatch get-metric-statistics \
    --namespace AWS/SSMCompliance \
    --metric-name "$metric" \
    --dimensions Name=ComplianceType,Value=Patch Name=ResourceId,Value="$instance_id" \
    --start-time "$(date -u -d "${LOOKBACK_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --period "$METRIC_PERIOD" \
    --statistics "$stat_type" \
    --region "${REGION}" \
    --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

calculate_sum() { jq -r '.Datapoints[].Sum' 2>/dev/null | awk '{s+=$1} END {if(NR==0) print 0; else printf "%.0f", s}'; }

analyze_instance() {
  local inst_json="$1"
  local id platform platform_ver agent_version
  id=$(echo "$inst_json" | jq -r '.InstanceId')
  platform=$(echo "$inst_json" | jq -r '.PlatformName // ""')
  platform_ver=$(echo "$inst_json" | jq -r '.PlatformVersion // ""')
  agent_version=$(echo "$inst_json" | jq -r '.AgentVersion // ""')

  TOTAL_INSTANCES=$((TOTAL_INSTANCES + 1))
  log_message INFO "Analyzing instance: ${id}"

  local comp_json
  comp_json=$(get_instance_compliance "$id")
  local non_compliant_count critical_missing
  non_compliant_count=$(echo "$comp_json" | jq '[.ComplianceItems[] | select(.Status=="NON_COMPLIANT")] | length' 2>/dev/null)
  critical_missing=$(echo "$comp_json" | jq '[.ComplianceItems[] | select(.Status=="NON_COMPLIANT" and (.Severity=="CRITICAL" or .Severity=="HIGH"))] | length' 2>/dev/null)

  local issue=0
  if (( non_compliant_count >= NONCOMPLIANT_WARN )); then
    INSTANCES_NONCOMPLIANT=$((INSTANCES_NONCOMPLIANT + 1))
    issue=1
    record_issue "Instance ${id} non-compliant count ${non_compliant_count}"
  fi
  if (( critical_missing >= CRITICAL_MISSING_WARN )); then
    INSTANCES_CRITICAL_MISSING=$((INSTANCES_CRITICAL_MISSING + 1))
    issue=1
    record_issue "Instance ${id} critical/security missing ${critical_missing}"
  fi

  # Agent version (flag empty/unknown)
  if [[ -z "$agent_version" || "$agent_version" == "null" ]]; then
    INSTANCES_AGENT_OUTDATED=$((INSTANCES_AGENT_OUTDATED + 1))
    record_issue "Instance ${id} missing/outdated SSM Agent version"
  fi

  {
    echo "Instance: ${id}"
    echo "  Platform: ${platform} ${platform_ver}"
    echo "  SSM Agent: ${agent_version:-unknown}"
    echo "  Non-compliant Items: ${non_compliant_count}"
    echo "  Critical/High Missing: ${critical_missing}"
  } >> "$OUTPUT_FILE"

  echo "" >> "$OUTPUT_FILE"
}

main() {
  write_header

  local instances_json
  instances_json=$(list_instances)
  local inst_count
  inst_count=$(echo "$instances_json" | jq -r '.InstanceInformationList | length')

  if [[ "$inst_count" == "0" ]]; then
    log_message WARN "No managed instances found"
    echo "No managed instances found." >> "$OUTPUT_FILE"
    exit 0
  fi

  echo "Total Managed Instances: ${inst_count}" >> "$OUTPUT_FILE"
  echo "" >> "$OUTPUT_FILE"

  while read -r inst; do
    analyze_instance "$inst"
  done <<< "$(echo "$instances_json" | jq -c '.InstanceInformationList[]')"

  {
    echo "Summary"
    echo "-------"
    echo "Total Instances: ${TOTAL_INSTANCES}"
    echo "Instances Non-compliant: ${INSTANCES_NONCOMPLIANT}"
    echo "Instances Critical Missing: ${INSTANCES_CRITICAL_MISSING}"
    echo "Instances Agent Outdated/Missing: ${INSTANCES_AGENT_OUTDATED}"
  } >> "$OUTPUT_FILE"

  if (( ${#ISSUES[@]} > 0 )); then
    log_message WARN "Issues detected: ${#ISSUES[@]}"
    local joined
    joined=$(printf '%s\n' "${ISSUES[@]}")
    send_slack_alert "SSM Patch Compliance Monitor detected issues:\n${joined}" "WARNING"
    send_email_alert "SSM Patch Compliance Monitor Alerts" "${joined}" || true
  else
    log_message INFO "No issues detected"
  fi

  log_message INFO "Report written to ${OUTPUT_FILE}"
  echo "Report: ${OUTPUT_FILE}"
}

main "$@"

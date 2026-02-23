#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-attachments-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-attachments-audit"
LOG_FILE="/var/log/aws-organizations-policy-attachments-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policy Attachments Auditor" > "${REPORT_DIR}/header.txt"
  echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"
}

log_message() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

send_slack_alert() {
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    return 0
  fi
  local payload
  payload=$(jq -n --arg t "$1" '{text:$t}')
  curl -s -S -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

check_cli_tools() {
  if ! command -v aws >/dev/null 2>&1; then
    log_message ERROR "aws CLI not found; aborting"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_message ERROR "jq not found; aborting"
    exit 2
  fi
}

audit_attachments() {
  log_message INFO "Enumerating policies and their attachments"
  report="${REPORT_DIR}/policy_attachments.txt"
  echo "Policy Attachments Report" > "$report"

  # Known policy filters
  filters=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")

  for f in "${filters[@]}"; do
    log_message INFO "Listing policies for filter: $f"
    pols=$(aws organizations list-policies --filter "$f" 2>/dev/null || echo '{}')
    ids=$(echo "$pols" | jq -r '.Policies[]?.Id // empty')
    if [[ -z "$ids" ]]; then
      echo "$f: no policies found" >> "$report"
      continue
    fi
    for pid in $ids; do
      pdesc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      pname=$(echo "$pdesc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
      echo "Policy: $pid ($pname) [filter=$f]" >> "$report"

      # List targets for this policy
      targets=$(aws organizations list-targets-for-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      tcount=$(echo "$targets" | jq '.Targets | length')
      echo "  Attached targets: $tcount" >> "$report"
      if [[ "$tcount" -eq 0 ]]; then
        echo "  FLAG: policy not attached to any target" >> "$report"
        log_message WARN "Policy $pid ($pname) has no attachments"
      else
        echo "$targets" | jq -r '.Targets[] | "  - \(.TargetId) (\(.TargetType))"' >> "$report" 2>/dev/null || true
      fi

      # Save raw target list for debugging
      echo "$targets" > "${REPORT_DIR}/${pid}_targets.json"
      echo "" >> "$report"
    done
  done
}

audit_unattached_policies() {
  log_message INFO "Searching for policies that exist but aren't attached anywhere"
  unattached_report="${REPORT_DIR}/unattached_policies.txt"
  echo "Unattached Policies" > "$unattached_report"

  filters=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")
  for f in "${filters[@]}"; do
    pols=$(aws organizations list-policies --filter "$f" 2>/dev/null || echo '{}')
    ids=$(echo "$pols" | jq -r '.Policies[]?.Id // empty')
    for pid in $ids; do
      targets=$(aws organizations list-targets-for-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      tcount=$(echo "$targets" | jq '.Targets | length')
      if [[ "$tcount" -eq 0 ]]; then
        echo "$pid (filter=$f)" >> "$unattached_report"
      fi
    done
  done
}

finalize() {
  log_message INFO "Policy attachments audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy attachments audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_attachments
  audit_unattached_policies
  finalize
}

write_header() { mkdir -p "${REPORT_DIR}"; echo "Policy attachments audit" > "${REPORT_DIR}/header.txt"; echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"; }

main "$@"
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-attachments-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-attachments-audit"
LOG_FILE="/var/log/aws-organizations-policy-attachments-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policy Attachments Auditor" > "${REPORT_DIR}/header.txt"
  echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"
}

log_message() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

send_slack_alert() {
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then
    return 0
  fi
  local payload
  payload=$(jq -n --arg t "$1" '{text:$t}')
  curl -s -S -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

check_cli_tools() {
  if ! command -v aws >/dev/null 2>&1; then
    log_message ERROR "aws CLI not found; aborting"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_message ERROR "jq not found; aborting"
    exit 2
  fi
}

audit_policy_attachments() {
  log_message INFO "Listing all organization policies"
  all_policies=$(aws organizations list-policies --filter ALL 2>/dev/null || echo '{}')
  policy_ids=$(echo "$all_policies" | jq -r '.Policies[]?.Id // empty')

  echo "Policy attachments audit" > "${REPORT_DIR}/attachments_summary.txt"

  for pid in $policy_ids; do
    desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
    pname=$(echo "$desc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
    echo "Policy: $pid ($pname)" >> "${REPORT_DIR}/attachments_summary.txt"

    # list targets for policy
    targets=$(aws organizations list-targets-for-policy --policy-id "$pid" 2>/dev/null || echo '{}')
    tcount=$(echo "$targets" | jq '.Targets | length')
    if [[ "$tcount" -eq 0 ]]; then
      echo "  Attached to: NONE - FLAG: un-attached policy" >> "${REPORT_DIR}/attachments_summary.txt"
      log_message WARN "Policy $pid ($pname) is not attached to any target"
    else
      echo "  Attached to: $tcount targets" >> "${REPORT_DIR}/attachments_summary.txt"
      echo "$targets" > "${REPORT_DIR}/${pid}_targets.json"
    fi

    echo "" >> "${REPORT_DIR}/attachments_summary.txt"
  done
}

audit_unattached_policies() {
  # Identify policies that exist but are not attached anywhere and may be orphaned
  log_message INFO "Checking for unattached policies"
  unattached=$(awk '/Policy:/{p=$2;next} /Attached to: 0 targets/ {print p}' "${REPORT_DIR}/attachments_summary.txt" 2>/dev/null || true)
  # simple note in report
  if [[ -n "$unattached" ]]; then
    echo "Unattached policies:" > "${REPORT_DIR}/unattached_policies.txt"
    for p in $unattached; do
      echo "$p" >> "${REPORT_DIR}/unattached_policies.txt"
    done
  fi
}

finalize() {
  log_message INFO "Policy attachments audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy attachments audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_policy_attachments
  audit_unattached_policies
  finalize
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-usage-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-usage-audit"
LOG_FILE="/var/log/aws-organizations-policy-usage-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policy Usage Auditor" > "${REPORT_DIR}/header.txt"
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

audit_usage() {
  log_message INFO "Enumerating organization policies and usage metrics"
  report="${REPORT_DIR}/policy_usage_summary.txt"
  echo "Policy Usage Summary" > "$report"

  filters=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")
  for f in "${filters[@]}"; do
    echo "Filter: $f" >> "$report"
    pols=$(aws organizations list-policies --filter "$f" 2>/dev/null || echo '{}')
    ids=$(echo "$pols" | jq -r '.Policies[]?.Id // empty')
    if [[ -z "$ids" ]]; then
      echo "  no policies" >> "$report"
      continue
    fi
    for pid in $ids; do
      pdesc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      pname=$(echo "$pdesc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
      content=$(echo "$pdesc" | jq -r '.Policy.Content // ""')
      # content length heuristic
      clen=$(echo -n "$content" | wc -c)

      targets=$(aws organizations list-targets-for-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      tcount=$(echo "$targets" | jq '.Targets | length')

      echo "  Policy: $pid ($pname)" >> "$report"
      echo "    Content size: ${clen} bytes" >> "$report"
      echo "    Attached targets: ${tcount}" >> "$report"

      if [[ $tcount -eq 0 ]]; then
        echo "    FLAG: Not attached to any target" >> "$report"
        log_message WARN "Policy $pid ($pname) has no attachments"
      fi

      # Save a small sample of the content for review
      echo "$content" | head -c 8192 > "${REPORT_DIR}/${pid}_sample.txt" || true
      echo "" >> "$report"
    done
  done
}

finalize() {
  log_message INFO "Policy usage audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy usage audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_usage
  finalize
}

main "$@"

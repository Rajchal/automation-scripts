#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-expiration-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-expiration-audit"
LOG_FILE="/var/log/aws-organizations-policy-expiration-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policy Expiration Auditor" > "${REPORT_DIR}/header.txt"
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
  for cmd in aws jq grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message ERROR "$cmd not found; aborting"
      exit 2
    fi
  done
}

audit_expirations() {
  log_message INFO "Checking policies for expiration-like indicators"
  echo "Policy expiration report" > "${REPORT_DIR}/policy_expiration_summary.txt"

  filters=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")
  for f in "${filters[@]}"; do
    pols=$(aws organizations list-policies --filter "$f" 2>/dev/null || echo '{}')
    ids=$(echo "$pols" | jq -r '.Policies[]?.Id // empty')
    if [[ -z "$ids" ]]; then
      echo "Filter $f: no policies" >> "${REPORT_DIR}/policy_expiration_summary.txt"
      continue
    fi
    for pid in $ids; do
      desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      pname=$(echo "$desc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
      content=$(echo "$desc" | jq -r '.Policy.Content // ""')

      echo "Policy: $pid ($pname) [filter=$f]" >> "${REPORT_DIR}/policy_expiration_summary.txt"

      # Heuristic checks for date-like strings or expiration keywords
      if echo "$content" | grep -E -q "(expire|expiration|expires|notAfter|notAfterDate|validUntil|expiry)" -i 2>/dev/null; then
        echo "  FOUND: expiration keyword in content" >> "${REPORT_DIR}/policy_expiration_summary.txt"
        log_message WARN "Policy $pid contains expiration keywords"
      fi

      # ISO8601 date detection
      if echo "$content" | grep -E -q "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}" 2>/dev/null; then
        echo "  FOUND: ISO8601 timestamp present in content" >> "${REPORT_DIR}/policy_expiration_summary.txt"
      fi

      # Save excerpt for review
      echo "$content" | head -c 8192 > "${REPORT_DIR}/${pid}_sample.txt" || true
      echo "" >> "${REPORT_DIR}/policy_expiration_summary.txt"
    done
  done
}

finalize() {
  log_message INFO "Policy expiration audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy expiration audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_expirations
  finalize
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policy-lastmodified-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policy-lastmodified-audit"
LOG_FILE="/var/log/aws-organizations-policy-lastmodified-auditor.log"

write_header() { mkdir -p "${REPORT_DIR}"; echo "AWS Organizations Policy Last-Modified Auditor" > "${REPORT_DIR}/header.txt"; echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"; }

log_message() {
  local level="$1"; shift
  local msg="$*"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

send_slack_alert() {
  if [[ -z "${SLACK_WEBHOOK:-}" ]]; then return 0; fi
  local payload
  payload=$(jq -n --arg t "$1" '{text:$t}')
  curl -s -S -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK" || true
}

check_tools() {
  for c in aws jq; do
    if ! command -v "$c" >/dev/null 2>&1; then
      log_message ERROR "$c not found; aborting"
      exit 2
    fi
  done
}

audit_lastmodified() {
  log_message INFO "Gathering policies and last-modified data"
  out="${REPORT_DIR}/policy_lastmodified.txt"
  echo "Policy last-modified report" > "$out"

  filters=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")
  for f in "${filters[@]}"; do
    echo "Filter: $f" >> "$out"
    pols=$(aws organizations list-policies --filter "$f" 2>/dev/null || echo '{}')
    ids=$(echo "$pols" | jq -r '.Policies[]?.Id // empty')
    if [[ -z "$ids" ]]; then
      echo "  no policies" >> "$out"
      continue
    fi
    for pid in $ids; do
      desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
      name=$(echo "$desc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
      # try multiple common timestamp fields
      lastmod=$(echo "$desc" | jq -r '.Policy.PolicySummary.LastUpdatedTimestamp // .Policy.PolicySummary.LastModifiedDate // .Policy.PolicySummary.CreatedTimestamp // .Policy.PolicySummary.CreationDate // empty')
      if [[ -z "$lastmod" ]]; then
        lastmod="(unknown)"
      fi
      echo "  $pid ($name): last-modified: $lastmod" >> "$out"
    done
    echo "" >> "$out"
  done
}

finalize() {
  log_message INFO "Policy last-modified audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policy last-modified audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_tools
  audit_lastmodified
  finalize
}

main "$@"

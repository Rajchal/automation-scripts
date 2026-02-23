#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-duplicate-policies-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-duplicate-policies-audit"
LOG_FILE="/var/log/aws-organizations-duplicate-policies-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Duplicate Policies Auditor" > "${REPORT_DIR}/header.txt"
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

check_tools() {
  if ! command -v aws >/dev/null 2>&1; then
    log_message ERROR "aws CLI not found; aborting"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_message ERROR "jq not found; aborting"
    exit 2
  fi
  if ! command -v sha1sum >/dev/null 2>&1; then
    log_message ERROR "sha1sum not found; aborting"
    exit 2
  fi
}

gather_policies() {
  log_message INFO "Gathering all organization policies"
  # Get all policy types
  types=("SERVICE_CONTROL_POLICY" "TAG_POLICY" "BACKUP_POLICY" "AISERVICES_OPT_OUT_POLICY")
  > "${REPORT_DIR}/all_policies.json"
  for t in "${types[@]}"; do
    aws organizations list-policies --filter "$t" 2>/dev/null | jq ".Policies[]? | . + {__Type:\"$t\"}" >> "${REPORT_DIR}/all_policies.json" || true
  done
}

detect_duplicates() {
  log_message INFO "Detecting duplicate policies by content hash"
  declare -A hash_map
  > "${REPORT_DIR}/duplicates_summary.txt"
  # iterate through policy IDs
  jq -c '.[]' "${REPORT_DIR}/all_policies.json" 2>/dev/null | while read -r p; do
    pid=$(echo "$p" | jq -r '.Id')
    pname=$(echo "$p" | jq -r '.Name // "(no-name)"')
    ptype=$(echo "$p" | jq -r '.__Type // "(unknown)"')

    desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || echo '{}')
    content=$(echo "$desc" | jq -r '.Policy.Content // ""')

    # normalize by stripping whitespace and sorting JSON keys if possible
    normalized=$(echo "$content" | jq -S . 2>/dev/null || echo "$content" | tr -d '[:space:]')
    h=$(echo -n "$normalized" | sha1sum | awk '{print $1}')

    # append to per-hash file
    echo "$pid|$pname|$ptype" >> "${REPORT_DIR}/hash_${h}.list"
    echo "$normalized" > "${REPORT_DIR}/content_${pid}.json"
  done

  # Report hashes with multiple policies
  for f in "${REPORT_DIR}"/hash_*.list; do
    [[ -f "$f" ]] || continue
    count=$(wc -l < "$f" | tr -d ' ')
    if [[ "$count" -gt 1 ]]; then
      echo "Duplicate group (count=$count):" >> "${REPORT_DIR}/duplicates_summary.txt"
      cat "$f" >> "${REPORT_DIR}/duplicates_summary.txt"
      echo "" >> "${REPORT_DIR}/duplicates_summary.txt"
      log_message WARN "Found duplicate policy group in $f"
    fi
  done

  # If no duplicates found, note that
  if [[ ! -s "${REPORT_DIR}/duplicates_summary.txt" ]]; then
    echo "No duplicate policies found" > "${REPORT_DIR}/duplicates_summary.txt"
    log_message INFO "No duplicates detected"
  fi
}

finalize() {
  log_message INFO "Duplicate policies audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations duplicate policies audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_tools
  gather_policies
  detect_duplicates
  finalize
}

write_header() { mkdir -p "${REPORT_DIR}"; echo "Duplicate policies audit" > "${REPORT_DIR}/header.txt"; echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"; }

main "$@"

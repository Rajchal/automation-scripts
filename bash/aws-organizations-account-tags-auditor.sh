#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-account-tags-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-account-tags-audit"
LOG_FILE="/var/log/aws-organizations-account-tags-auditor.log"

# REQUIRED_TAGS can be a comma-separated list, e.g. "Owner,Environment,CostCenter"
REQUIRED_TAGS="${REQUIRED_TAGS:-Owner,Environment,CostCenter}"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Account Tags Auditor" > "${REPORT_DIR}/header.txt"
  echo "Run at: $(date -u +'%Y-%m-%dT%H:%M:%SZ')" >> "${REPORT_DIR}/header.txt"
  echo "Required tags: ${REQUIRED_TAGS}" >> "${REPORT_DIR}/header.txt"
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
  for cmd in aws jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message ERROR "$cmd not found; aborting"
      exit 2
    fi
  done
}

audit_account_tags() {
  log_message INFO "Listing organization accounts"
  accounts_json=$(aws organizations list-accounts 2>/dev/null || echo '{}')
  account_ids=$(echo "$accounts_json" | jq -r '.Accounts[]?.Id // empty')

  echo "AWS Organizations Account Tags Audit" > "${REPORT_DIR}/accounts_tags_summary.txt"

  IFS=',' read -r -a req_tags <<< "${REQUIRED_TAGS}"

  for aid in $account_ids; do
    log_message INFO "Inspecting account $aid"
    info=$(aws organizations describe-account --account-id "$aid" 2>/dev/null || echo '{}')
    aname=$(echo "$info" | jq -r '.Account.Name // "(no-name)"')

    # list tags for this account
    tags_json=$(aws organizations list-tags-for-resource --resource-id "$aid" 2>/dev/null || echo '{}')
    tags_count=$(echo "$tags_json" | jq '.Tags | length')

    echo "Account: $aid (${aname})" >> "${REPORT_DIR}/accounts_tags_summary.txt"
    echo "  Tags count: ${tags_count}" >> "${REPORT_DIR}/accounts_tags_summary.txt"

    # build map of tag keys present
    declare -A present
    for k in $(echo "$tags_json" | jq -r '.Tags[]?.Key // empty'); do
      present["$k"]=1
    done

    missing=()
    for t in "${req_tags[@]}"; do
      if [[ -z "${present[$t]:-}" ]]; then
        missing+=("$t")
      fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "  MISSING TAGS: ${missing[*]}" >> "${REPORT_DIR}/accounts_tags_summary.txt"
      log_message WARN "Account $aid missing tags: ${missing[*]}"
    else
      echo "  All required tags present" >> "${REPORT_DIR}/accounts_tags_summary.txt"
    fi

    # Save raw tags for reference
    echo "$tags_json" > "${REPORT_DIR}/${aid}_tags.json"
    echo "" >> "${REPORT_DIR}/accounts_tags_summary.txt"
  done
}

finalize() {
  log_message INFO "Account tags audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations account tags audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_tools
  audit_account_tags
  finalize
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-accounts-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-accounts-audit"
LOG_FILE="/var/log/aws-organizations-accounts-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Accounts Auditor" > "${REPORT_DIR}/header.txt"
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

audit_accounts() {
  log_message INFO "Listing organization accounts"
  accounts_json=$(aws organizations list-accounts 2>/dev/null || echo '{}')
  account_ids=$(echo "$accounts_json" | jq -r '.Accounts[]?.Id // empty')

  if [[ -z "$account_ids" ]]; then
    log_message WARN "No accounts found in Organization"
    echo "No accounts found" > "${REPORT_DIR}/accounts_summary.txt"
    return
  fi

  echo "AWS Organizations Accounts Audit" > "${REPORT_DIR}/accounts_summary.txt"

  for aid in $account_ids; do
    log_message INFO "Inspecting account $aid"
    info=$(aws organizations describe-account --account-id "$aid" 2>/dev/null || echo '{}')
    if [[ -z "$info" || "$info" == '{}' ]]; then
      echo "$aid: unable to describe" >> "${REPORT_DIR}/accounts_summary.txt"
      continue
    fi

    name=$(echo "$info" | jq -r '.Account.Name // "(no-name)"')
    email=$(echo "$info" | jq -r '.Account.Email // "(no-email)"')
    status=$(echo "$info" | jq -r '.Account.Status // "(unknown)"')
    joined_method=$(echo "$info" | jq -r '.Account.JoinedMethod // "(unknown)"')
    joined_ts=$(echo "$info" | jq -r '.Account.JoinedTimestamp // "(unknown)"')

    echo "Account: ${aid} (${name})" >> "${REPORT_DIR}/accounts_summary.txt"
    echo "  Email: ${email}" >> "${REPORT_DIR}/accounts_summary.txt"
    echo "  Status: ${status}" >> "${REPORT_DIR}/accounts_summary.txt"
    echo "  JoinedMethod: ${joined_method}" >> "${REPORT_DIR}/accounts_summary.txt"
    echo "  JoinedTimestamp: ${joined_ts}" >> "${REPORT_DIR}/accounts_summary.txt"

    # Heuristic flags
    if [[ "$status" != "ACTIVE" ]]; then
      echo "  FLAG: Account status is ${status}" >> "${REPORT_DIR}/accounts_summary.txt"
      log_message WARN "Account ${aid} status: ${status}"
    fi

    if [[ "$email" == "(no-email)" || -z "$email" ]]; then
      echo "  FLAG: missing contact email" >> "${REPORT_DIR}/accounts_summary.txt"
      log_message WARN "Account ${aid} missing email"
    fi

    # Check if account is a management account by checking 'JoinedMethod' is CREATED and role existence is unknown
    if [[ "$joined_method" == "INVITED" ]]; then
      echo "  NOTE: Account was invited to the Organization (JoinedMethod=INVITED)" >> "${REPORT_DIR}/accounts_summary.txt"
    fi

    # Save raw account JSON for debugging
    echo "$info" > "${REPORT_DIR}/${aid}_describe.json"

    echo "" >> "${REPORT_DIR}/accounts_summary.txt"
  done
}

finalize() {
  log_message INFO "Accounts audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations accounts audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_accounts
  finalize
}

main "$@"

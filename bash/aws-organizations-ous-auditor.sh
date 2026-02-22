#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-ous-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-ous-audit"
LOG_FILE="/var/log/aws-organizations-ous-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations OUs Auditor" > "${REPORT_DIR}/header.txt"
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

audit_ous() {
  log_message INFO "Listing roots"
  roots_json=$(aws organizations list-roots 2>/dev/null || echo '{}')
  root_ids=$(echo "$roots_json" | jq -r '.Roots[]?.Id // empty')

  echo "AWS Organizations OU Audit" > "${REPORT_DIR}/ous_summary.txt"

  for rid in $root_ids; do
    root_name=$(echo "$roots_json" | jq -r ".Roots[] | select(.Id==\"$rid\") | .Name")
    echo "Root: $rid ($root_name)" >> "${REPORT_DIR}/ous_summary.txt"
    log_message INFO "Processing root $rid"

    # BFS through OU tree (first two levels to avoid runaway recursion)
    first_level=$(aws organizations list-organizational-units-for-parent --parent-id "$rid" 2>/dev/null || echo '{}')
    first_ids=$(echo "$first_level" | jq -r '.OrganizationalUnits[]?.Id // empty')

    if [[ -z "$first_ids" ]]; then
      echo "  No OUs under root" >> "${REPORT_DIR}/ous_summary.txt"
      continue
    fi

    for ou in $first_ids; do
      ou_name=$(echo "$first_level" | jq -r ".OrganizationalUnits[] | select(.Id==\"$ou\") | .Name")
      echo "  OU: $ou ($ou_name)" >> "${REPORT_DIR}/ous_summary.txt"

      # Count attached SCPs
      attached=$(aws organizations list-policies-for-target --target-id "$ou" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
      scp_count=$(echo "$attached" | jq '.Policies | length')
      echo "    Attached SCPs: $scp_count" >> "${REPORT_DIR}/ous_summary.txt"

      if [[ "$scp_count" -eq 0 ]]; then
        echo "    FLAG: No SCPs attached to this OU" >> "${REPORT_DIR}/ous_summary.txt"
        log_message WARN "OU $ou ($ou_name) has no SCPs attached"
      fi

      # Count accounts in this OU
      accounts=$(aws organizations list-accounts-for-parent --parent-id "$ou" 2>/dev/null || echo '{}')
      account_count=$(echo "$accounts" | jq '.Accounts | length')
      echo "    Accounts: $account_count" >> "${REPORT_DIR}/ous_summary.txt"

      if [[ "$account_count" -eq 0 ]]; then
        echo "    NOTE: OU has no accounts assigned" >> "${REPORT_DIR}/ous_summary.txt"
      elif [[ "$account_count" -gt 50 ]]; then
        echo "    FLAG: OU has many accounts ($account_count) — consider splitting or reviewing organizational boundaries" >> "${REPORT_DIR}/ous_summary.txt"
        log_message WARN "OU $ou has $account_count accounts"
      fi

      # Inspect second-level OUs under this OU
      second_level=$(aws organizations list-organizational-units-for-parent --parent-id "$ou" 2>/dev/null || echo '{}')
      second_ids=$(echo "$second_level" | jq -r '.OrganizationalUnits[]?.Id // empty')
      if [[ -n "$second_ids" ]]; then
        echo "    Child OUs: " >> "${REPORT_DIR}/ous_summary.txt"
        for sou in $second_ids; do
          sname=$(echo "$second_level" | jq -r ".OrganizationalUnits[] | select(.Id==\"$sou\") | .Name")
          sa=$(aws organizations list-policies-for-target --target-id "$sou" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
          sc=$(echo "$sa" | jq '.Policies | length')
          echo "      - $sou ($sname): attached SCPs: $sc" >> "${REPORT_DIR}/ous_summary.txt"
          if [[ "$sc" -eq 0 ]]; then
            echo "        FLAG: child OU has no SCPs" >> "${REPORT_DIR}/ous_summary.txt"
            log_message WARN "Child OU $sou ($sname) has no SCPs"
          fi
        done
      fi
    done
    echo "" >> "${REPORT_DIR}/ous_summary.txt"
  done
}

finalize() {
  log_message INFO "OU audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations OUs audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_ous
  finalize
}

main "$@"

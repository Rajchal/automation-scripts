#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-guardrails-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-guardrails-audit"
LOG_FILE="/var/log/aws-organizations-guardrails-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Guardrails Auditor" > "${REPORT_DIR}/header.txt"
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
  for cmd in aws jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log_message ERROR "$cmd not found; aborting"
      exit 2
    fi
  done
}

audit_guardrails() {
  log_message INFO "Checking root and OU guardrails (SCP presence and diversity)"
  summary="${REPORT_DIR}/guardrails_summary.txt"
  echo "Guardrails audit" > "$summary"

  roots_json=$(aws organizations list-roots 2>/dev/null || echo '{}')
  root_ids=$(echo "$roots_json" | jq -r '.Roots[]?.Id // empty')

  for rid in $root_ids; do
    rname=$(echo "$roots_json" | jq -r ".Roots[] | select(.Id==\"$rid\") | .Name")
    echo "Root: $rid ($rname)" >> "$summary"

    # Check SCPs attached to root
    root_pols=$(aws organizations list-policies-for-target --target-id "$rid" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
    rpcount=$(echo "$root_pols" | jq '.Policies | length')
    echo "  SCPs attached to root: $rpcount" >> "$summary"
    if [[ "$rpcount" -eq 0 ]]; then
      echo "  FLAG: No SCPs attached to root — consider attaching baseline guardrails" >> "$summary"
      log_message WARN "Root $rid has no SCPs"
    fi

    # Inspect first-level OUs
    first_level=$(aws organizations list-organizational-units-for-parent --parent-id "$rid" 2>/dev/null || echo '{}')
    first_ids=$(echo "$first_level" | jq -r '.OrganizationalUnits[]?.Id // empty')
    for ou in $first_ids; do
      oname=$(echo "$first_level" | jq -r ".OrganizationalUnits[] | select(.Id==\"$ou\") | .Name")
      echo "  OU: $ou ($oname)" >> "$summary"

      # SCPs for OU
      ou_pols=$(aws organizations list-policies-for-target --target-id "$ou" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
      opcount=$(echo "$ou_pols" | jq '.Policies | length')
      echo "    SCPs attached: $opcount" >> "$summary"
      if [[ "$opcount" -eq 0 ]]; then
        echo "    FLAG: OU has no SCPs attached" >> "$summary"
        log_message WARN "OU $ou has no SCPs"
      fi

      # Simple diversity check: if all attached SCP names are identical or only one, flag for review
      names=$(echo "$ou_pols" | jq -r '.Policies[]?.Name // empty' | sort -u | tr '\n' ',' | sed 's/,$//')
      ncount=$(echo "$names" | awk -F',' '{print NF}')
      if [[ -z "$names" ]]; then
        names="(none)"
        ncount=0
      fi
      echo "    Attached SCP names (unique): $names" >> "$summary"
      if [[ "$ncount" -le 1 ]]; then
        echo "    NOTE: Single or no unique SCPs attached — review guardrails coverage" >> "$summary"
        log_message INFO "OU $ou has low SCP diversity ($ncount)"
      fi

      # Count accounts in OU
      acct=$(aws organizations list-accounts-for-parent --parent-id "$ou" 2>/dev/null || echo '{}')
      acount=$(echo "$acct" | jq '.Accounts | length')
      echo "    Accounts in OU: $acount" >> "$summary"
      if [[ "$acount" -gt 100 ]]; then
        echo "    FLAG: OU contains many accounts ($acount) — consider splitting or additional guardrails" >> "$summary"
        log_message WARN "OU $ou has $acount accounts"
      fi
    done
    echo "" >> "$summary"
  done
}

finalize() {
  log_message INFO "Guardrails audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations guardrails audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_tools
  audit_guardrails
  finalize
}

main "$@"

#!/bin/bash

################################################################################
# AWS Organizations Auditor
# Audits AWS Organizations: accounts, OUs, policies, and non-active accounts
################################################################################

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/organizations-audit-$(date +%s).txt"
LOG_FILE="${LOG_FILE:-/var/log/aws-organizations-audit.log}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

log_message() {
  local level="$1"; shift
  local msg="$@"
  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  echo "[${ts}] [${level}] ${msg}" | tee -a "${LOG_FILE}"
}

jq_safe() { jq -r "$1" 2>/dev/null || true; }

list_accounts() {
  aws organizations list-accounts --output json 2>/dev/null || echo '{}'
}

list_roots() {
  aws organizations list-roots --output json 2>/dev/null || echo '{}'
}

list_organizational_units_for_parent() {
  local parent_id="$1"
  aws organizations list-organizational-units-for-parent --parent-id "${parent_id}" --output json 2>/dev/null || echo '{}'
}

list_policies() {
  local type="$1"
  aws organizations list-policies --filter "${type}" --output json 2>/dev/null || echo '{}'
}

list_policies_for_target() {
  local target_id="$1"; local type="$2"
  aws organizations list-policies-for-target --target-id "${target_id}" --filter "${type}" --output json 2>/dev/null || echo '{}'
}

write_header() {
  {
    echo "AWS Organizations Audit"
    echo "========================="
    echo "Generated: $(date)"
    echo "Region (API calls): ${REGION}"
    echo ""
  } > "${OUTPUT_FILE}"
}

audit_accounts() {
  log_message INFO "Listing organization accounts"
  echo "=== Accounts ===" >> "${OUTPUT_FILE}"

  local accounts
  accounts=$(list_accounts)
  echo "${accounts}" | jq -c '.Accounts[]?' 2>/dev/null | while read -r a; do
    local id name email status joined_method joined_time arn
    id=$(echo "${a}" | jq_safe '.Id')
    name=$(echo "${a}" | jq_safe '.Name')
    email=$(echo "${a}" | jq_safe '.Email')
    status=$(echo "${a}" | jq_safe '.Status')
    joined_method=$(echo "${a}" | jq_safe '.JoinedMethod')
    joined_time=$(echo "${a}" | jq_safe '.JoinedTimestamp')
    arn=$(echo "${a}" | jq_safe '.Arn')

    echo "Account: ${name} (${id})" >> "${OUTPUT_FILE}"
    echo "  Email: ${email}" >> "${OUTPUT_FILE}"
    echo "  Status: ${status}" >> "${OUTPUT_FILE}"
    echo "  JoinedMethod: ${joined_method}" >> "${OUTPUT_FILE}"
    echo "  JoinedTimestamp: ${joined_time}" >> "${OUTPUT_FILE}"
    echo "  Arn: ${arn}" >> "${OUTPUT_FILE}"

    if [[ "${status}" != "ACTIVE" ]]; then
      echo "  WARNING: Account not ACTIVE" >> "${OUTPUT_FILE}"
    fi

    # attached policies
    local sp
    sp=$(list_policies_for_target "${id}" "SERVICE_CONTROL_POLICY")
    if [[ $(echo "${sp}" | jq '.Policies | length' 2>/dev/null || echo 0) -gt 0 ]]; then
      echo "  Service Control Policies attached:" >> "${OUTPUT_FILE}"
      echo "${sp}" | jq -c '.Policies[]?' 2>/dev/null | while read -r p; do
        echo "    - $(echo \"${p}\" | jq_safe '.Name') ($(echo \"${p}\" | jq_safe '.Id'))" >> "${OUTPUT_FILE}"
      done
    fi

    echo "" >> "${OUTPUT_FILE}"
  done

  echo "" >> "${OUTPUT_FILE}"
}

audit_organizational_units() {
  log_message INFO "Listing roots and OUs"
  echo "=== Organizational Units ===" >> "${OUTPUT_FILE}"

  local roots
  roots=$(list_roots)
  echo "${roots}" | jq -c '.Roots[]?' 2>/dev/null | while read -r r; do
    local rid rname
    rid=$(echo "${r}" | jq_safe '.Id')
    rname=$(echo "${r}" | jq_safe '.Name')
    echo "Root: ${rname} (${rid})" >> "${OUTPUT_FILE}"

    local ous
    ous=$(list_organizational_units_for_parent "${rid}")
    echo "${ous}" | jq -c '.OrganizationalUnits[]?' 2>/dev/null | while read -r ou; do
      local ouid ouname
      ouid=$(echo "${ou}" | jq_safe '.Id')
      ouname=$(echo "${ou}" | jq_safe '.Name')
      echo "  OU: ${ouname} (${ouid})" >> "${OUTPUT_FILE}"

      local policies
      policies=$(list_policies_for_target "${ouid}" "SERVICE_CONTROL_POLICY")
      if [[ $(echo "${policies}" | jq '.Policies | length' 2>/dev/null || echo 0) -gt 0 ]]; then
        echo "    Policies:" >> "${OUTPUT_FILE}"
        echo "${policies}" | jq -c '.Policies[]?' 2>/dev/null | while read -r p; do
          echo "      - $(echo \"${p}\" | jq_safe '.Name') ($(echo \"${p}\" | jq_safe '.Id'))" >> "${OUTPUT_FILE}"
        done
      fi
    done

    echo "" >> "${OUTPUT_FILE}"
  done

  echo "" >> "${OUTPUT_FILE}"
}

send_slack_alert() {
  local non_active_count="$1"
  [[ -z "${SLACK_WEBHOOK}" ]] && return 0
  local color="good"
  (( non_active_count > 0 )) && color="warning"

  local payload
  payload=$(cat <<EOF
{
  "text": "AWS Organizations Audit Summary",
  "attachments": [
    {
      "color": "${color}",
      "fields": [
        {"title": "Non-active Accounts", "value": "${non_active_count}", "short": true},
        {"title": "Region", "value": "${REGION}", "short": true},
        {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": true}
      ]
    }
  ]
}
EOF
)
  curl -s -X POST -H 'Content-type: application/json' --data "${payload}" "${SLACK_WEBHOOK}" >/dev/null || log_message WARN "Failed to send Slack alert"
}

main() {
  log_message INFO "Starting Organizations audit"
  write_header
  audit_accounts
  audit_organizational_units
  log_message INFO "Organizations audit complete. Report: ${OUTPUT_FILE}"

  local non_active
  non_active=$(grep "WARNING: Account not ACTIVE" "${OUTPUT_FILE}" | wc -l || echo 0)
  send_slack_alert "${non_active}"
  cat "${OUTPUT_FILE}"
}

main "$@"

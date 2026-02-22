#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-policies-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-policies-audit"
LOG_FILE="/var/log/aws-organizations-policies-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Policies Auditor" > "${REPORT_DIR}/header.txt"
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

check_organizations_cli() {
  if ! command -v aws >/dev/null 2>&1; then
    log_message ERROR "aws CLI not found; aborting"
    exit 2
  fi
  if ! command -v jq >/dev/null 2>&1; then
    log_message ERROR "jq not found; aborting"
    exit 2
  fi
}

audit_policies() {
  log_message INFO "Listing Service Control Policies (SCPs)"
  policies_json=$(aws organizations list-policies --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
  policy_ids=$(echo "$policies_json" | jq -r '.Policies[]?.Id // empty')

  if [[ -z "$policy_ids" ]]; then
    log_message WARN "No Service Control Policies found in this Organization"
    echo "No SCPs found" > "${REPORT_DIR}/scps_summary.txt"
    return
  fi

  echo "SCPs audit report" > "${REPORT_DIR}/scps_summary.txt"
  for pid in $policy_ids; do
    log_message INFO "Inspecting SCP: $pid"
    desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || true)
    if [[ -z "$desc" ]]; then
      echo "$pid: unable to describe" >> "${REPORT_DIR}/scps_summary.txt"
      continue
    fi
    name=$(echo "$desc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
    content=$(echo "$desc" | jq -r '.Policy.Content // ""')

    # Save raw content for offline inspection
    echo "$content" | jq . > "${REPORT_DIR}/${pid}_content.json" 2>/dev/null || echo "$content" > "${REPORT_DIR}/${pid}_content.raw"

    # Simple heuristic checks: look for Allow with wildcard actions/resources
    allow_wildcard=$(echo "$content" | jq -r '.. | objects | select(.Effect? == "Allow") | (.Action // .NotAction // []) | @json' 2>/dev/null || echo '[]')
    wildcard_found=0
    if echo "$allow_wildcard" | grep -q '\"\*\"' 2>/dev/null; then
      wildcard_found=1
    fi

    if [[ $wildcard_found -eq 1 ]]; then
      echo "$pid ($name): Contains an Allow with wildcard Action/Resource — flagged" >> "${REPORT_DIR}/scps_summary.txt"
      log_message WARN "SCP $pid appears to allow wildcard actions/resources"
    else
      echo "$pid ($name): No obvious allow-* wildcard detected" >> "${REPORT_DIR}/scps_summary.txt"
    fi
  done
}

audit_targets() {
  log_message INFO "Checking roots and OUs for attached SCPs"
  roots=$(aws organizations list-roots 2>/dev/null || echo '{}')
  root_ids=$(echo "$roots" | jq -r '.Roots[]?.Id // empty')
  echo "Organization targets audit" > "${REPORT_DIR}/targets_summary.txt"

  for rid in $root_ids; do
    root_name=$(echo "$roots" | jq -r ".Roots[] | select(.Id==\"$rid\") | .Name")
    attached=$(aws organizations list-policies-for-target --target-id "$rid" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
    count=$(echo "$attached" | jq '.Policies | length')
    echo "Root $rid ($root_name): attached SCPs: $count" >> "${REPORT_DIR}/targets_summary.txt"

    # list child OUs recursively (first level)
    ous=$(aws organizations list-organizational-units-for-parent --parent-id "$rid" 2>/dev/null || echo '{}')
    ou_ids=$(echo "$ous" | jq -r '.OrganizationalUnits[]?.Id // empty')
    for ou in $ou_ids; do
      ou_name=$(echo "$ous" | jq -r ".OrganizationalUnits[] | select(.Id==\"$ou\") | .Name")
      a=$(aws organizations list-policies-for-target --target-id "$ou" --filter SERVICE_CONTROL_POLICY 2>/dev/null || echo '{}')
      n=$(echo "$a" | jq '.Policies | length')
      if [[ "$n" -eq 0 ]]; then
        echo "OU $ou ($ou_name): NO SCPs attached — consider attaching restrictive SCPs" >> "${REPORT_DIR}/targets_summary.txt"
        log_message WARN "OU $ou has no SCPs attached"
      else
        echo "OU $ou ($ou_name): attached SCPs: $n" >> "${REPORT_DIR}/targets_summary.txt"
      fi
    done
  done
}

finalize() {
  log_message INFO "Audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations policies audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_organizations_cli
  audit_policies
  audit_targets
  finalize
}

main "$@"

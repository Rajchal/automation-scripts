#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-organizations-tag-policies-auditor.sh"
REPORT_DIR="/tmp/aws-organizations-tag-policies-audit"
LOG_FILE="/var/log/aws-organizations-tag-policies-auditor.log"

write_header() {
  mkdir -p "${REPORT_DIR}"
  echo "AWS Organizations Tag Policies Auditor" > "${REPORT_DIR}/header.txt"
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

audit_tag_policies() {
  log_message INFO "Listing Tag Policies"
  policies_json=$(aws organizations list-policies --filter TAG_POLICY 2>/dev/null || echo '{}')
  policy_ids=$(echo "$policies_json" | jq -r '.Policies[]?.Id // empty')

  if [[ -z "$policy_ids" ]]; then
    log_message WARN "No Tag Policies found in this Organization"
    echo "No Tag Policies found" > "${REPORT_DIR}/tag_policies_summary.txt"
    return
  fi

  echo "Tag Policies audit report" > "${REPORT_DIR}/tag_policies_summary.txt"
  for pid in $policy_ids; do
    log_message INFO "Inspecting Tag Policy: $pid"
    desc=$(aws organizations describe-policy --policy-id "$pid" 2>/dev/null || true)
    if [[ -z "$desc" ]]; then
      echo "$pid: unable to describe" >> "${REPORT_DIR}/tag_policies_summary.txt"
      continue
    fi
    name=$(echo "$desc" | jq -r '.Policy.PolicySummary.Name // "(no-name)"')
    content=$(echo "$desc" | jq -r '.Policy.Content // ""')

    # Save raw content for offline inspection
    echo "$content" | jq . > "${REPORT_DIR}/${pid}_content.json" 2>/dev/null || echo "$content" > "${REPORT_DIR}/${pid}_content.raw"

    # Heuristics: look for enforcement rules or wide tag key patterns
    if echo "$content" | grep -q 'enforced' 2>/dev/null; then
      echo "$pid ($name): Appears to have enforced rules" >> "${REPORT_DIR}/tag_policies_summary.txt"
    else
      echo "$pid ($name): No enforced rules detected" >> "${REPORT_DIR}/tag_policies_summary.txt"
    fi

    if echo "$content" | grep -q 'keyPattern' 2>/dev/null; then
      echo "$pid ($name): Uses keyPattern — review for overly permissive patterns" >> "${REPORT_DIR}/tag_policies_summary.txt"
    fi
  done
}

audit_targets() {
  log_message INFO "Checking which targets have Tag Policies attached"
  targets_json=$(aws organizations list-roots 2>/dev/null || echo '{}')
  root_ids=$(echo "$targets_json" | jq -r '.Roots[]?.Id // empty')

  echo "Tag policy attachments" > "${REPORT_DIR}/attachments_summary.txt"
  for rid in $root_ids; do
    attached=$(aws organizations list-policies-for-target --target-id "$rid" --filter TAG_POLICY 2>/dev/null || echo '{}')
    n=$(echo "$attached" | jq '.Policies | length')
    echo "Root $rid: tag policies attached: $n" >> "${REPORT_DIR}/attachments_summary.txt"

    ous=$(aws organizations list-organizational-units-for-parent --parent-id "$rid" 2>/dev/null || echo '{}')
    ou_ids=$(echo "$ous" | jq -r '.OrganizationalUnits[]?.Id // empty')
    for ou in $ou_ids; do
      a=$(aws organizations list-policies-for-target --target-id "$ou" --filter TAG_POLICY 2>/dev/null || echo '{}')
      m=$(echo "$a" | jq '.Policies | length')
      if [[ "$m" -eq 0 ]]; then
        echo "OU $ou: no tag policies attached" >> "${REPORT_DIR}/attachments_summary.txt"
        log_message WARN "OU $ou has no tag policies"
      else
        echo "OU $ou: tag policies attached: $m" >> "${REPORT_DIR}/attachments_summary.txt"
      fi
    done
  done
}

finalize() {
  log_message INFO "Tag policies audit complete. Reports in ${REPORT_DIR}"
  send_slack_alert "AWS Organizations tag policies audit completed. Reports: ${REPORT_DIR}"
}

main() {
  write_header
  check_cli_tools
  audit_tag_policies
  audit_targets
  finalize
}

main "$@"

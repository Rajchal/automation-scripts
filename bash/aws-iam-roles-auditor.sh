#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-roles-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

log_message() {
  local msg="$1"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${msg}" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  local text="$1"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    jq -n --arg t "$text" '{text:$t}' | curl -s -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  cat > "$REPORT_FILE" <<EOF
AWS IAM Roles Permissions Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

policy_has_wildcard_allow() {
  local policy_json="$1"
  echo "$policy_json" | jq -e '
    .Statement // [] |
    (if type=="object" then [.] else . end) |
    map(select(.Effect=="Allow")) |
    map(select(
      (.Action=="*") or
      (.Action | (if type=="array" then any(.=="*") else false end)) or
      (.Resource=="*") or
      (.Resource | (if type=="array" then any(.=="*") else false end))
    )) | length > 0
  '
}

check_role() {
  local role_name="$1"
  local findings=()

  # Inline policies
  local inline_names
  inline_names=$(aws iam list-role-policies --role-name "$role_name" --query 'PolicyNames[]' --output text 2>/dev/null || true)
  if [ -n "$inline_names" ]; then
    for pn in $inline_names; do
      local doc
      doc=$(aws iam get-role-policy --role-name "$role_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || true)
      if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
        findings+=("INLINE_POLICY:$pn contains wildcard Allow")
      fi
    done
  fi

  # Attached managed policies
  local attached
  attached=$(aws iam list-attached-role-policies --role-name "$role_name" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true)
  if [ -n "$attached" ]; then
    for arn in $attached; do
      local ver
      ver=$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || true)
      if [ -n "$ver" ]; then
        local doc
        doc=$(aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --query 'PolicyVersion.Document' --output json 2>/dev/null || true)
        if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
          findings+=("MANAGED_POLICY:${arn} contains wildcard Allow")
        fi
      fi
    done
  fi

  if [ ${#findings[@]} -gt 0 ]; then
    echo "Role: $role_name" >> "$REPORT_FILE"
    for f in "${findings[@]}"; do
      echo "  - $f" >> "$REPORT_FILE"
    done
    echo >> "$REPORT_FILE"
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting IAM roles auditor"

  local roles_json
  roles_json=$(aws iam list-roles --output json 2>/dev/null)
  if [ -z "$roles_json" ]; then
    log_message "No roles retrieved or AWS CLI failed"
    exit 0
  fi

  local role_names
  role_names=$(echo "$roles_json" | jq -r '.Roles[].RoleName')
  local any_findings=0
  for r in $role_names; do
    if check_role "$r"; then
      any_findings=1
      log_message "Findings for role $r"
    fi
  done

  if [ "$any_findings" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM roles auditor found potential wildcard Allow statements. See $REPORT_FILE on host."
  else
    log_message "No wildcard Allow statements found on scanned roles"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"

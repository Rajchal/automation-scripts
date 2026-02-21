#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-inline-policy-auditor.sh"
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
AWS IAM Inline Policy Auditor
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
      (.Action | (if type=="array" then any(.=="*") else .=="*" end)) or
      (.Resource=="*") or
      (.Resource | (if type=="array" then any(.=="*") else .=="*" end))
    )) | length > 0
  '
}

check_inline_policies_for_entity() {
  local entity_type="$1"  # user|group|role
  local entity_name="$2"
  local policy_names
  case "$entity_type" in
    user) policy_names=$(aws iam list-user-policies --user-name "$entity_name" --query 'PolicyNames[]' --output text 2>/dev/null || true) ;;
    group) policy_names=$(aws iam list-group-policies --group-name "$entity_name" --query 'PolicyNames[]' --output text 2>/dev/null || true) ;;
    role) policy_names=$(aws iam list-role-policies --role-name "$entity_name" --query 'PolicyNames[]' --output text 2>/dev/null || true) ;;
    *) return 1 ;;
  esac

  if [ -z "$policy_names" ]; then
    return 1
  fi

  local found=0
  for pn in $policy_names; do
    local doc
    case "$entity_type" in
      user) doc=$(aws iam get-user-policy --user-name "$entity_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || echo '{}') ;;
      group) doc=$(aws iam get-group-policy --group-name "$entity_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || echo '{}') ;;
      role) doc=$(aws iam get-role-policy --role-name "$entity_name" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || echo '{}') ;;
    esac
    if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
      echo "$entity_type: $entity_name - INLINE_POLICY:$pn contains wildcard Allow" >> "$REPORT_FILE"
      found=1
    fi
  done
  return $found
}

main() {
  write_header
  log_message "Starting IAM inline-policy auditor"

  # Users
  users=$(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null || true)
  for u in $users; do
    if check_inline_policies_for_entity user "$u"; then
      log_message "Findings for user $u"
    fi
  done

  # Groups
  groups=$(aws iam list-groups --query 'Groups[].GroupName' --output text 2>/dev/null || true)
  for g in $groups; do
    if check_inline_policies_for_entity group "$g"; then
      log_message "Findings for group $g"
    fi
  done

  # Roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || true)
  for r in $roles; do
    if check_inline_policies_for_entity role "$r"; then
      log_message "Findings for role $r"
    fi
  done

  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM inline-policy auditor found potential wildcard Allow statements. See $REPORT_FILE on host."
  else
    log_message "No wildcard Allow statements detected in inline policies"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-inline-policy-auditor.sh"
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
AWS IAM Inline Policy Auditor
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

check_inline_policies_for_entity() {
  local entity_type="$1" # user|role|group
  local entity_name="$2"
  local list_cmd get_cmd

  case "$entity_type" in
    user)
      list_cmd=(aws iam list-user-policies --user-name "$entity_name" --query 'PolicyNames[]' --output text)
      get_cmd_base=(aws iam get-user-policy --user-name "$entity_name")
      ;;
    role)
      list_cmd=(aws iam list-role-policies --role-name "$entity_name" --query 'PolicyNames[]' --output text)
      get_cmd_base=(aws iam get-role-policy --role-name "$entity_name")
      ;;
    group)
      list_cmd=(aws iam list-group-policies --group-name "$entity_name" --query 'PolicyNames[]' --output text)
      get_cmd_base=(aws iam get-group-policy --group-name "$entity_name")
      ;;
    *)
      return 1
      ;;
  esac

  local policy_names
  policy_names=$("${list_cmd[@]}" 2>/dev/null || echo "")
  if [ -z "$policy_names" ]; then
    return 1
  fi

  for pn in $policy_names; do
    local doc
    doc=$("${get_cmd_base[@]}" --policy-name "$pn" --query 'PolicyDocument' --output json 2>/dev/null || echo '{}')
    if policy_has_wildcard_allow "$doc" >/dev/null 2>&1; then
      echo "${entity_type^}: $entity_name - INLINE_POLICY:$pn contains wildcard Allow" >> "$REPORT_FILE"
    fi
    # best-effort size check (string length)
    local len
    len=$(echo "$doc" | wc -c)
    if [ "$len" -gt 8000 ]; then
      echo "${entity_type^}: $entity_name - INLINE_POLICY:$pn size=${len} bytes (large)" >> "$REPORT_FILE"
    fi
  done
}

main() {
  write_header
  log_message "Starting IAM inline policy auditor"

  # Users
  local users
  users=$(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null || echo "")
  for u in $users; do
    check_inline_policies_for_entity user "$u" || true
  done

  # Roles
  local roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || echo "")
  for r in $roles; do
    check_inline_policies_for_entity role "$r" || true
  done

  # Groups
  local groups
  groups=$(aws iam list-groups --query 'Groups[].GroupName' --output text 2>/dev/null || echo "")
  for g in $groups; do
    check_inline_policies_for_entity group "$g" || true
  done

  if [ -s "$REPORT_FILE" ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM inline-policy auditor found issues. See $REPORT_FILE on host."
  else
    log_message "No inline policy issues found"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-permissions-boundary-auditor.sh"
LOG_FILE="/var/log/${SCRIPT_NAME%.sh}.log"
REPORT_FILE="/tmp/${SCRIPT_NAME%.sh}-$(date +%s).txt"

log_message() {
  local msg="$1"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') - ${msg}'" | tee -a "$LOG_FILE"
}

send_slack_alert() {
  local text="$1"
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    jq -n --arg t "$text" '{text:$t}' | curl -s -X POST -H 'Content-type: application/json' --data @- "$SLACK_WEBHOOK" >/dev/null || true
  fi
}

write_header() {
  cat > "$REPORT_FILE" <<EOF
AWS IAM Permissions Boundary Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

# Check roles, users, and groups for missing permissions boundaries
check_roles() {
  local roles
  roles=$(aws iam list-roles --query 'Roles[].RoleName' --output text 2>/dev/null || echo "")
  for r in $roles; do
    local pb
    pb=$(aws iam get-role --role-name "$r" --query 'Role.PermissionsBoundary.PolicyName' --output text 2>/dev/null || echo "None")
    if [ "$pb" = "None" ] || [ -z "$pb" ] || [ "$pb" = "null" ]; then
      echo "Role: $r - MISSING permissions boundary" >> "$REPORT_FILE"
    fi
  done
}

check_users() {
  local users
  users=$(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null || echo "")
  for u in $users; do
    local pb
    pb=$(aws iam get-user --user-name "$u" --query 'User.PermissionsBoundary.PolicyName' --output text 2>/dev/null || echo "None")
    if [ "$pb" = "None" ] || [ -z "$pb" ] || [ "$pb" = "null" ]; then
      echo "User: $u - MISSING permissions boundary" >> "$REPORT_FILE"
    fi
  done
}

check_groups() {
  local groups
  groups=$(aws iam list-groups --query 'Groups[].GroupName' --output text 2>/dev/null || echo "")
  for g in $groups; do
    # Groups do not support permissions boundaries currently; note for completeness
    echo "Group: $g - NOTE: IAM groups do not support permissions boundaries (check attached policies)" >> "$REPORT_FILE"
  done
}

main() {
  write_header
  log_message "Starting IAM permissions-boundary auditor"

  check_roles
  check_users
  check_groups

  if [ -s "$REPORT_FILE" ]; then
    log_message "Findings written to $REPORT_FILE"
    send_slack_alert "IAM permissions-boundary auditor found items requiring review; report at $REPORT_FILE"
  else
    log_message "No missing permissions boundaries detected"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"

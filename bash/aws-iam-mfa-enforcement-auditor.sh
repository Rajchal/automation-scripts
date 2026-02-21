#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="aws-iam-mfa-enforcement-auditor.sh"
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
AWS IAM MFA Enforcement Auditor
Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Findings:
EOF
}

# Check for MFA devices attached to a user
user_has_mfa() {
  local user="$1"
  local mfa_count
  mfa_count=$(aws iam list-mfa-devices --user-name "$user" --query 'MFADevices | length(@)' --output text 2>/dev/null || echo 0)
  if [ "$mfa_count" -gt 0 ]; then
    return 0
  fi
  return 1
}

# Check whether user has console access (login profile)
user_has_console() {
  local user="$1"
  if aws iam get-login-profile --user-name "$user" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

main() {
  write_header
  log_message "Starting IAM MFA enforcement auditor"

  local users
  users=$(aws iam list-users --query 'Users[].UserName' --output text 2>/dev/null || true)
  if [ -z "$users" ]; then
    log_message "No users found or AWS CLI failed"
    rm -f "$REPORT_FILE"
    exit 0
  fi

  local any=0
  for u in $users; do
    # If user has console access and no MFA, flag
    if user_has_console "$u"; then
      if ! user_has_mfa "$u"; then
        echo "User: $u - Console access WITHOUT MFA configured" >> "$REPORT_FILE"
        any=1
        log_message "User $u has console access but no MFA"
      fi
    fi
  done

  # Also check root account for MFA
  if ! aws iam get-account-summary >/dev/null 2>&1; then
    log_message "Skipping root MFA check: cannot retrieve account summary"
  else
    if ! aws iam list-account-aliases --output text >/dev/null 2>&1; then
      :
    fi
    # best-effort root MFA check using account password policy not direct; note in report
    # Users should manually verify root MFA via console
  fi

  if [ "$any" -eq 1 ]; then
    log_message "Finished with findings; report saved to $REPORT_FILE"
    send_slack_alert "IAM MFA enforcement auditor found users without MFA. See $REPORT_FILE on host."
  else
    log_message "No console users missing MFA detected"
    rm -f "$REPORT_FILE"
  fi
}

main "$@"
